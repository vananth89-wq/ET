/**
 * BankAccountsPortlet — Set-Snapshot Edition
 *
 * Implements the view / draft / pending / history UX described in
 * docs/set-snapshot-design.md §7.1.
 *
 * Used in:
 *   • MyProfile/index.tsx      — ESS self-service (15th cutoff, workflow gate)
 *   • AddEmployee.tsx          — hire flow (isNewHire=true, effective_from=hire date)
 *   • EmployeeEditPanel.tsx    — admin direct-edit (editMode=true)
 *
 * RPCs consumed (set-snapshot, mig 324–331):
 *   get_employee_bank_account_set(p_employee_id, p_as_of?)
 *     → { ok, set: {...}|null, items: [...] }
 *   submit_bank_account_set(p_employee_id, p_effective_from, p_items)
 *     → { ok, workflow, instance_id|set_id, effective_from, change_summary }
 *   get_employee_bank_account_set_history(p_employee_id)
 *     → { ok, sets: [...] }
 *
 * Legacy RPCs (upsert_bank_account, get_employee_bank_accounts) are NOT called
 * here. They stay alive until Phase 6 cleanup.
 *
 * Bank-specific rules vs DependentsPortlet:
 *   - 15th-of-month submission cutoff (unless isBankException / isNewHire)
 *   - 20th-of-month approver cutoff enforced server-side
 *   - Exactly one item with is_primary=true per set (onSetPrimary auto-unsets others)
 *   - Country-specific field rules (IFSC/IND, IBAN/PAK+SAU, branch_code/LKA)
 *   - Attachments: always [] in Phase 5 (deferred to Phase 6)
 */

import React, { useState, useEffect, useCallback, useRef } from 'react';
import { supabase } from '../../lib/supabase';
import { usePicklistValues } from '../../hooks/usePicklistValues';
import { randomUUID } from '../../utils/randomUUID';

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

interface BankSetItem {
  id: string;
  bank_account_group_id: string;
  country_code: string;
  currency_code: string;
  bank_name: string;
  branch_name?: string;
  branch_code?: string;
  account_holder_name: string;
  account_number: string;
  ifsc_code?: string;
  iban?: string;
  swift_bic?: string;
  is_primary: boolean;
  attachments: unknown[];
}

interface BankSetInfo {
  id: string;
  employee_id: string;
  effective_from: string;
  effective_to: string;
  is_active: boolean;
  created_at: string;
}

interface DraftBankItem {
  _localId: string;
  bank_account_group_id: string | null; // null = new account
  country_code: string;
  currency_code: string;
  bank_name: string;
  branch_name: string;
  branch_code: string;
  account_holder_name: string;
  account_number: string;
  ifsc_code: string;
  iban: string;
  swift_bic: string;
  is_primary: boolean;
  // UI helpers (not sent to backend)
  _countryPvId: string;
  _bankPvId: string;
  // Draft state flags
  _new: boolean;
  _removed: boolean;
  _editing: boolean;
  _hasError: boolean;
  _errors: Record<string, string>;
  // Attachments (proof of account)
  _attachments: BankAttachment[];
  // Snapshot for amendment detection
  _original: {
    country_code: string; currency_code: string; bank_name: string;
    branch_name: string; branch_code: string; account_holder_name: string;
    account_number: string; ifsc_code: string; iban: string;
    swift_bic: string; is_primary: boolean;
  } | null;
}

interface BankSetHistoryRow {
  set_id: string;
  effective_from: string;
  effective_to: string;
  is_active: boolean;
  created_at: string;
  item_count: number;
  items: Array<{
    bank_account_group_id: string;
    bank_name: string;
    account_holder_name: string;
    account_number: string;
    is_primary: boolean;
  }>;
}

// Backward-compat exports so callers typing against the old model still compile
export interface BankAccount {
  id: string;
  bank_account_group_id: string;
  country_code: string;
  currency_code: string;
  bank_name: string;
  branch_name?: string;
  branch_code?: string;
  account_holder_name: string;
  account_number: string;
  ifsc_code?: string;
  iban?: string;
  swift_bic?: string;
  is_primary: boolean;
  effective_from: string;
  effective_to: string;
  is_active: boolean;
  created_at: string;
  attachments: unknown[];
}

export interface BankAttachment {
  id?: string;
  file_name: string;
  file_type: string;
  file_size: number;
  storage_path: string;
  uploaded_at?: string;
  _file?: File;
  _localUrl?: string;
}

export interface BankAccountsPortletProps {
  employeeId: string;
  hireDate?: string;
  isNewHire?: boolean;
  readOnly?: boolean;
  canCreate?: boolean;  // gates "Add Account" button
  canEdit?: boolean;    // gates editing fields on existing accounts
  canDelete?: boolean;  // gates the trash/remove button on existing accounts
  /** In-flight pending_change count for profile_bank from the parent. Blocks editing. */
  pendingCount?: number;
  /**
   * True when the current user holds bank_exceptions / admin / hr role.
   * Exempt from the 15th submission / 20th approval cutoffs.
   */
  isBankException?: boolean;
  /** Auto-enter draft mode. EmployeeEditPanel uses this. */
  editMode?: boolean;
  onChanged?: () => void;
  /** Called after every load or submit with the current active account count.
   *  Use this to track whether the employee has ≥1 bank account. */
  onAccountCountChange?: (hasAccounts: boolean) => void;
  /** @deprecated Unused in set-snapshot model — hire wizard uses saveTriggerRef instead. */
  preloadedAccounts?: BankAccount[];
  /** Hire-wizard integration: call to trigger submit+validation. Returns true on success. */
  saveTriggerRef?: React.MutableRefObject<(() => Promise<boolean>) | null>;
  /** editMode compat for EmployeeEditPanel. Wired to handleSubmit. */
  saveAllRef?: React.MutableRefObject<(() => Promise<boolean>) | null>;
  /** WorkflowReview context: effective_from shown as display text, all cards auto-expanded, pencil hidden. */
  reviewMode?: boolean;
  /**
   * When provided, the portlet renders its own section header (title + History/Edit buttons
   * in one row), matching the Personal Info SectionHeader pattern. MyProfile should NOT
   * render a separate <SectionTitle> when this prop is set.
   */
  sectionTitle?: {
    icon: string;
    text: string;
    pending?: number;
    onViewProgress?: () => void;
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Constants & helpers
// ─────────────────────────────────────────────────────────────────────────────

const REF_TO_ISO: Record<string, string> = {
  G001: 'IND', G002: 'SAU', G003: 'ARE', G004: 'MYS', G005: 'SGP',
  G006: 'USA', G007: 'GBR', G008: 'QAT', G009: 'KWT', G010: 'BHR',
  G011: 'OMN', G012: 'PAK', G013: 'LKA', G014: 'BGD', G015: 'NPL',
};

const FIELD_RULES: Record<string, {
  branchName: 'mandatory' | 'optional' | 'hidden';
  branchCode: 'mandatory' | 'optional' | 'hidden';
  ifsc: 'mandatory' | 'optional' | 'hidden';
  iban: 'mandatory' | 'optional' | 'hidden';
}> = {
  IND: { branchName: 'mandatory', branchCode: 'hidden',    ifsc: 'mandatory', iban: 'hidden'    },
  LKA: { branchName: 'mandatory', branchCode: 'mandatory', ifsc: 'hidden',    iban: 'hidden'    },
  PAK: { branchName: 'optional',  branchCode: 'hidden',    ifsc: 'hidden',    iban: 'mandatory' },
  SAU: { branchName: 'optional',  branchCode: 'hidden',    ifsc: 'hidden',    iban: 'mandatory' },
};

function getRules(isoCode: string) {
  return FIELD_RULES[isoCode] ?? {
    branchName: 'optional', branchCode: 'hidden', ifsc: 'hidden', iban: 'optional',
  };
}

function fmtDate(val?: string): string {
  if (!val || val === '9999-12-31') return 'Open-ended';
  return new Date(val + 'T00:00:00').toLocaleDateString('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
  });
}

function fmtMonthYear(isoDate: string): string {
  const d = new Date(isoDate + 'T00:00:00');
  return d.toLocaleDateString('en-GB', { month: 'long', year: 'numeric' });
}

function maskAccount(num: string): string {
  if (num.length <= 4) return num;
  return '•'.repeat(num.length - 4) + num.slice(-4);
}

function firstOfCurrentMonth(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-01`;
}

function snapToFirstOfMonth(iso: string): string {
  if (!iso) return iso;
  return iso.slice(0, 7) + '-01';
}

function isItemAmended(item: DraftBankItem): boolean {
  if (!item._original || item._new || item._removed) return false;
  const o = item._original;
  return (
    item.country_code       !== o.country_code       ||
    item.currency_code      !== o.currency_code      ||
    item.bank_name          !== o.bank_name          ||
    item.branch_name        !== o.branch_name        ||
    item.branch_code        !== o.branch_code        ||
    item.account_holder_name !== o.account_holder_name ||
    item.account_number     !== o.account_number     ||
    item.ifsc_code          !== o.ifsc_code          ||
    item.iban               !== o.iban               ||
    item.swift_bic          !== o.swift_bic          ||
    item.is_primary         !== o.is_primary         ||
    // Attachment added or removed compared to original
    (item._attachments ?? []).filter(a => !(a as any)._removed).length !==
      (item._original as any)?.attachmentCount
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// FieldCell — shared label+value cell used in view and history panels
// ─────────────────────────────────────────────────────────────────────────────

export function FieldCell({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div style={{ padding: '6px 0', borderBottom: '1px solid #F3F4F6' }}>
      <div style={{ fontSize: 10.5, color: '#9CA3AF', marginBottom: 2, fontWeight: 500,
        textTransform: 'uppercase', letterSpacing: 0.5 }}>
        {label}
      </div>
      <div style={{ fontSize: 13, color: '#111827', fontWeight: 500,
        fontFamily: mono ? 'monospace' : undefined }}>
        {value}
      </div>
    </div>
  );
}

const iconBtnBase: React.CSSProperties = {
  width: 28, height: 28, borderRadius: 6,
  border: '1px solid #E5E7EB', background: 'none',
  cursor: 'pointer', display: 'inline-flex', alignItems: 'center',
  justifyContent: 'center', color: '#6B7280', flexShrink: 0,
};

// BankAttachmentEditActions — view + download buttons inside draft edit rows
function BankAttachmentEditActions({ att }: { att: BankAttachment }) {
  const [signedUrl, setSignedUrl] = useState<string | null>(null);
  useEffect(() => {
    if (att._localUrl || !att.storage_path) return;
    supabase.storage.from('hr-attachments')
      .createSignedUrl(att.storage_path, 3600)
      .then(({ data }) => { if (data?.signedUrl) setSignedUrl(data.signedUrl); });
  }, [att.storage_path, att._localUrl]);

  const url = att._localUrl ?? signedUrl;
  if (!url) return null;
  const btnStyle: React.CSSProperties = {
    width: 26, height: 26, borderRadius: 6,
    background: '#F3F4F6', border: '1px solid #E5E7EB',
    display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
    color: '#374151', textDecoration: 'none', flexShrink: 0,
  };
  return (
    <div style={{ display: 'flex', gap: 5, flexShrink: 0 }}>
      <a href={url} target="_blank" rel="noreferrer" style={btnStyle} title="View">
        <i className="fa-solid fa-eye" style={{ fontSize: 11 }} />
      </a>
      {!att._localUrl && (
        <a href={url} download={att.file_name} target="_blank" rel="noreferrer" style={btnStyle} title="Download">
          <i className="fa-solid fa-download" style={{ fontSize: 11 }} />
        </a>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// BankAttachmentRow — signed-URL link for a single bank proof-of-account file
// ─────────────────────────────────────────────────────────────────────────────

function BankAttachmentRow({ att }: { att: BankAttachment }) {
  const [url, setUrl] = useState<string | null>(att._localUrl ?? null);
  useEffect(() => {
    if (att._localUrl || !att.storage_path) return;
    supabase.storage.from('hr-attachments')
      .createSignedUrl(att.storage_path, 3600)
      .then(({ data }) => { if (data?.signedUrl) setUrl(data.signedUrl); });
  }, [att.storage_path, att._localUrl]);

  const icon = (att.file_type ?? '').includes('pdf') ? 'fa-file-pdf' : 'fa-file-image';
  const sizeKb = att.file_size ? (att.file_size / 1024).toFixed(0) : '?';
  return (
    <div style={{ background: '#F9FAFB', border: '1px solid #E5E7EB',
      borderRadius: 7, padding: '8px 10px', fontSize: 12.5, display: 'flex', alignItems: 'center', gap: 10 }}>
      <i className={`fa-regular ${icon}`} style={{ color: '#6366F1', fontSize: 16, flexShrink: 0 }} />
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontWeight: 600, color: '#111827', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
          {att.file_name}
        </div>
        <div style={{ color: '#9CA3AF', fontSize: 11 }}>{sizeKb} KB</div>
      </div>
      {url && (
        <div style={{ display: 'flex', gap: 6, flexShrink: 0 }}>
          <a href={url} target="_blank" rel="noreferrer"
            style={{ width: 28, height: 28, borderRadius: 6, background: '#F3F4F6', border: '1px solid #E5E7EB',
              display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#374151', textDecoration: 'none' }}
            title="View">
            <i className="fa-solid fa-eye" style={{ fontSize: 12 }} />
          </a>
          <a href={url} download={att.file_name}
            target="_blank" rel="noreferrer"
            style={{ width: 28, height: 28, borderRadius: 6, background: '#F3F4F6', border: '1px solid #E5E7EB',
              display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#374151', textDecoration: 'none' }}
            title="Download">
            <i className="fa-solid fa-download" style={{ fontSize: 12 }} />
          </a>
        </div>
      )}
    </div>
  );
}

// BankViewCard — read-only card in view mode (no edit/amend buttons)
// ─────────────────────────────────────────────────────────────────────────────

function BankViewCard({ item, effectiveFrom, isNewHire, onEdit }: { item: BankSetItem; effectiveFrom?: string; isNewHire?: boolean; onEdit?: () => void }) {
  const attachments = (item.attachments ?? []) as BankAttachment[];
  const rules = getRules(item.country_code);

  function fieldCells() {
    const cells: React.ReactNode[] = [];
    cells.push(<FieldCell key="holder"   label="Account Holder" value={item.account_holder_name || '—'} />);
    cells.push(<FieldCell key="bank"     label="Bank Name"      value={item.bank_name || '—'} />);
    cells.push(<FieldCell key="accNo"    label="Account Number" value={maskAccount(item.account_number)} mono />);
    cells.push(<FieldCell key="country"  label="Country"        value={item.country_code || '—'} />);
    cells.push(<FieldCell key="currency" label="Currency"       value={item.currency_code || '—'} />);
    if (!isNewHire)
      cells.push(<FieldCell key="effFrom"  label="Effective From" value={fmtDate(effectiveFrom)} />);
    if (rules.branchName !== 'hidden' && item.branch_name)
      cells.push(<FieldCell key="branchN" label="Branch"       value={item.branch_name} />);
    if (rules.branchCode !== 'hidden' && item.branch_code)
      cells.push(<FieldCell key="branchC" label="Branch Code"  value={item.branch_code} mono />);
    if (rules.ifsc !== 'hidden' && item.ifsc_code)
      cells.push(<FieldCell key="ifsc"    label="IFSC"         value={item.ifsc_code} mono />);
    if (rules.iban !== 'hidden' && item.iban)
      cells.push(<FieldCell key="iban"    label="IBAN"         value={item.iban} mono />);
    if (item.swift_bic)
      cells.push(<FieldCell key="swift"   label="SWIFT / BIC"  value={item.swift_bic} mono />);
    return cells;
  }

  return (
    <div style={{
      border: `1.5px solid ${item.is_primary ? '#6366F1' : '#E5E7EB'}`,
      borderRadius: 10, marginBottom: 12,
      background: '#fff', overflow: 'hidden',
    }}>
      {/* Header */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: 10,
        padding: '12px 14px', borderBottom: '1px solid #F3F4F6',
      }}>
        <i className="fa-solid fa-building-columns"
          style={{ color: '#6366F1', fontSize: 16, flexShrink: 0 }} />
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontWeight: 600, fontSize: 14, color: '#111827',
            overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
            {item.bank_name}
          </div>
          <div style={{ fontSize: 11.5, color: '#9CA3AF', marginTop: 1 }}>
            {item.account_holder_name}
          </div>
        </div>
        {item.is_primary && (
          <span style={{ background: '#EEF2FF', color: '#4F46E5',
            borderRadius: 5, padding: '2px 8px', fontSize: 11, fontWeight: 700, flexShrink: 0 }}>
            Primary
          </span>
        )}
        {onEdit && (
          <button onClick={onEdit} title="Edit" style={{
            background: 'none', border: '1px solid #E5E7EB', borderRadius: 6,
            cursor: 'pointer', color: '#6B7280', padding: '4px 8px',
            display: 'inline-flex', alignItems: 'center', gap: 4,
            fontSize: 12, flexShrink: 0,
          }}>
            <i className="fa-solid fa-pen" style={{ fontSize: 11 }} />
          </button>
        )}
      </div>

      {/* Field grid + attachments */}
      <div style={{ padding: '10px 14px 14px' }}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: '0 16px' }}>
          {fieldCells()}
        </div>
        {attachments.length > 0 && (
          <div style={{ marginTop: 10 }}>
            <div style={{ fontSize: 10.5, color: '#9CA3AF', fontWeight: 600,
              textTransform: 'uppercase', letterSpacing: 0.5, marginBottom: 6 }}>
              Proof of Account
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              {attachments.map((a, i) => (
                <BankAttachmentRow key={a.storage_path ?? i} att={a} />
              ))}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// DraftBankItemEditor — inline form inside a draft item card
// ─────────────────────────────────────────────────────────────────────────────

interface DraftBankItemEditorProps {
  item: DraftBankItem;
  onChange: (update: Partial<DraftBankItem>) => void;
  onSetPrimary: () => void; // sets this item as primary, unsets others
  hasError: boolean;
  employeeId: string;
}

function DraftBankItemEditor({ item, onChange, onSetPrimary, hasError, employeeId }: DraftBankItemEditorProps) {
  const { picklistValues } = usePicklistValues();

  const countries = picklistValues.filter(p => p.picklistId === 'ID_COUNTRY' && p.active !== false);

  const banks = item._countryPvId
    ? picklistValues
        .filter(p => p.picklistId === 'BANK' && p.parentValueId === item._countryPvId && p.active !== false)
        .sort((a, b) => a.value.localeCompare(b.value))
    : [];

  // Auto-resolve currency when country changes
  useEffect(() => {
    if (!item._countryPvId) return;
    const countryPv = picklistValues.find(p => String(p.id) === item._countryPvId);
    if (!countryPv) return;
    const meta = (countryPv as any).meta;
    if (meta?.currencyId) {
      const currPv = picklistValues.find(p => String(p.id) === meta.currencyId);
      if (currPv) {
        const currMeta = (currPv as any).meta;
        const code = currMeta?.code || currPv.value;
        if (code !== item.currency_code) onChange({ currency_code: code });
        return;
      }
    }
    const currencyMap: Record<string, string> = {
      IND: 'INR', LKA: 'LKR', PAK: 'PKR', SAU: 'SAR',
      ARE: 'AED', MYS: 'MYR', SGP: 'SGD', USA: 'USD',
      GBR: 'GBP', QAT: 'QAR', KWT: 'KWD', BHR: 'BHD',
      OMN: 'OMR', BGD: 'BDT', NPL: 'NPR',
    };
    const code = currencyMap[item.country_code] || '';
    if (code !== item.currency_code) onChange({ currency_code: code });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [item._countryPvId, picklistValues.length]);

  // Once banks list is ready in amend mode, resolve _bankPvId from bank_name
  useEffect(() => {
    if (item._new || item._bankPvId || banks.length === 0) return;
    const match = banks.find((b: any) => b.value === item.bank_name);
    if (match) onChange({ _bankPvId: String(match.id) });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [banks.length]);

  const rules = getRules(item.country_code);
  const fe = (cond: boolean): React.CSSProperties =>
    cond && hasError ? { border: '1px solid #FCA5A5' } : {};

  return (
    <div style={{ padding: '12px 14px', borderTop: '1px solid #F3F4F6', background: '#FAFAFE' }}>
      <div className="emp-field-grid emp-grid-2" style={{ gap: 10 }}>

        {/* Country */}
        <div className={`form-group ${hasError && !item._countryPvId ? 'form-group--error' : ''}`}>
          <label><i className="fa-solid fa-earth-americas fa-fw" /> Country *</label>
          <select
            value={item._countryPvId}
            style={fe(!item._countryPvId)}
            onChange={e => {
              const pvId = e.target.value;
              const pv = picklistValues.find(p => String(p.id) === pvId);
              const iso = (pv as any)?.meta?.isoCode ?? REF_TO_ISO[pv?.refId ?? ''] ?? '';
              onChange({
                _countryPvId: pvId,
                country_code: iso,
                _bankPvId: '',
                bank_name: '',
                currency_code: '',
                // Reset country-specific fields
                branch_name: '', branch_code: '', ifsc_code: '', iban: '',
              });
            }}>
            <option value="">-- Select Country --</option>
            {countries.map(c => (
              <option key={String(c.id)} value={String(c.id)}>{c.value}</option>
            ))}
          </select>
          {hasError && !item._countryPvId && (
            <div className="field-error">Country is required.</div>
          )}
        </div>

        {/* Currency — read-only, auto-resolved */}
        <div className="form-group">
          <label><i className="fa-solid fa-coins fa-fw" /> Currency</label>
          <input type="text" value={item.currency_code} readOnly
            style={{ background: '#F9FAFB', color: '#6B7280' }}
            placeholder="Auto-resolved from Country" />
        </div>

        {/* Bank Name — full width */}
        <div className={`form-group ${hasError && !item.bank_name.trim() ? 'form-group--error' : ''}`}
          style={{ gridColumn: '1 / -1' }}>
          <label><i className="fa-solid fa-building-columns fa-fw" /> Bank Name *</label>
          {banks.length > 0 ? (
            <select
              value={item._bankPvId}
              style={fe(!item.bank_name.trim())}
              onChange={e => {
                const pvId = e.target.value;
                const bk = banks.find((b: any) => String(b.id) === pvId);
                onChange({ _bankPvId: pvId, bank_name: bk ? (bk as any).value : '' });
              }}>
              <option value="">-- Select Bank --</option>
              {banks.map((b: any) => (
                <option key={b.id} value={String(b.id)}>{b.value}</option>
              ))}
            </select>
          ) : (
            <input type="text" value={item.bank_name}
              style={fe(!item.bank_name.trim())}
              onChange={e => onChange({ bank_name: e.target.value })}
              placeholder={item.country_code ? 'Bank name' : 'Select a country first'} />
          )}
          {hasError && !item.bank_name.trim() && (
            <div className="field-error">Bank name is required.</div>
          )}
        </div>

        {/* Branch Name */}
        {rules.branchName !== 'hidden' ? (
          <div className={`form-group ${hasError && rules.branchName === 'mandatory' && !item.branch_name.trim() ? 'form-group--error' : ''}`}>
            <label>
              <i className="fa-solid fa-map-pin fa-fw" /> Branch Name
              {rules.branchName === 'mandatory' && <span style={{ color: '#e53935' }}> *</span>}
            </label>
            <input type="text" value={item.branch_name}
              style={fe(rules.branchName === 'mandatory' && !item.branch_name.trim())}
              onChange={e => onChange({ branch_name: e.target.value })}
              placeholder="Branch name" />
            {hasError && rules.branchName === 'mandatory' && !item.branch_name.trim() && (
              <div className="field-error">Branch name is required.</div>
            )}
          </div>
        ) : <div />}

        {/* Branch Code (LKA only) — paired with Branch Name */}
        {rules.branchCode !== 'hidden' ? (
          <div className={`form-group ${hasError && rules.branchCode === 'mandatory' && !item.branch_code.trim() ? 'form-group--error' : ''}`}>
            <label>
              <i className="fa-solid fa-code fa-fw" /> Branch Code
              {rules.branchCode === 'mandatory' && <span style={{ color: '#e53935' }}> *</span>}
            </label>
            <input type="text" value={item.branch_code}
              style={fe(rules.branchCode === 'mandatory' && !item.branch_code.trim())}
              onChange={e => onChange({ branch_code: e.target.value })}
              placeholder="e.g. 7047" />
            {hasError && rules.branchCode === 'mandatory' && !item.branch_code.trim() && (
              <div className="field-error">Branch code is required.</div>
            )}
          </div>
        ) : <div />}

        {/* Account Holder — full width */}
        <div className={`form-group ${hasError && !item.account_holder_name.trim() ? 'form-group--error' : ''}`}
          style={{ gridColumn: '1 / -1' }}>
          <label><i className="fa-solid fa-user fa-fw" /> Account Holder Name *</label>
          <input type="text" value={item.account_holder_name}
            style={fe(!item.account_holder_name.trim())}
            onChange={e => onChange({ account_holder_name: e.target.value })}
            placeholder="Full name on account" />
          {hasError && !item.account_holder_name.trim() && (
            <div className="field-error">Account holder name is required.</div>
          )}
        </div>

        {/* Account Number */}
        <div className={`form-group ${hasError && !item.account_number.trim() ? 'form-group--error' : ''}`}>
          <label><i className="fa-solid fa-hashtag fa-fw" /> Account Number *</label>
          <input type="text" value={item.account_number}
            style={fe(!item.account_number.trim())}
            onChange={e => onChange({ account_number: e.target.value })}
            placeholder="Bank account number" />
          {hasError && !item.account_number.trim() && (
            <div className="field-error">Account number is required.</div>
          )}
        </div>

        {/* IBAN — paired with Account Number */}
        {rules.iban !== 'hidden' ? (
          <div className={`form-group ${hasError && rules.iban === 'mandatory' && !item.iban.trim() ? 'form-group--error' : ''}`}>
            <label>
              <i className="fa-solid fa-barcode fa-fw" /> IBAN
              {rules.iban === 'mandatory'
                ? <span style={{ color: '#e53935' }}> *</span>
                : <span style={{ color: '#9CA3AF', fontSize: 11, marginLeft: 4 }}>(Optional)</span>}
            </label>
            <input type="text" value={item.iban}
              style={fe(rules.iban === 'mandatory' && !item.iban.trim())}
              onChange={e => onChange({ iban: e.target.value.toUpperCase() })}
              placeholder="e.g. PK36SCBL0000001123456702" />
            {hasError && rules.iban === 'mandatory' && !item.iban.trim() && (
              <div className="field-error">IBAN is required.</div>
            )}
          </div>
        ) : <div />}

        {/* SWIFT/BIC */}
        <div className="form-group">
          <label>
            <i className="fa-solid fa-globe fa-fw" /> SWIFT / BIC
            <span style={{ color: '#9CA3AF', fontSize: 11, marginLeft: 4 }}>(Optional)</span>
          </label>
          <input type="text" value={item.swift_bic}
            onChange={e => onChange({ swift_bic: e.target.value.toUpperCase() })}
            placeholder="e.g. HDFCINBB" maxLength={11} />
        </div>

        {/* IFSC — paired with SWIFT/BIC */}
        {rules.ifsc !== 'hidden' ? (
          <div className={`form-group ${hasError && rules.ifsc === 'mandatory' && !item.ifsc_code.trim() ? 'form-group--error' : ''}`}>
            <label>
              <i className="fa-solid fa-fingerprint fa-fw" /> IFSC Code
              {rules.ifsc === 'mandatory' && <span style={{ color: '#e53935' }}> *</span>}
            </label>
            <input type="text" value={item.ifsc_code}
              style={fe(rules.ifsc === 'mandatory' && !item.ifsc_code.trim())}
              onChange={e => onChange({ ifsc_code: e.target.value.toUpperCase() })}
              placeholder="e.g. SBIN0001234" maxLength={11} />
            {hasError && rules.ifsc === 'mandatory' && !item.ifsc_code.trim() && (
              <div className="field-error">IFSC code is required.</div>
            )}
          </div>
        ) : <div />}

        {/* Primary flag — full width */}
        <div className={`form-group ${hasError && !item.is_primary ? 'form-group--error' : ''}`}
          style={{ gridColumn: '1 / -1' }}>
          <label>
            <i className="fa-solid fa-star fa-fw" style={{ color: item.is_primary ? '#F59E0B' : '#9CA3AF' }} />
            {' '}Primary Account
          </label>
          <label style={{ display: 'flex', alignItems: 'center',
            gap: 8, fontSize: 13, cursor: 'pointer', paddingTop: 6 }}>
            <input
              type="checkbox"
              checked={item.is_primary}
              onChange={e => {
                if (e.target.checked) onSetPrimary();
                else onChange({ is_primary: false });
              }}
            />
            Set as primary account
          </label>
          {hasError && !item.is_primary && (
            <div className="field-error">Exactly one account must be marked as primary.</div>
          )}
        </div>

      </div>

      {/* ── Attachments (proof of account) ──────────────────────────────── */}
      <div style={{ marginTop: 12 }}>
        <div style={{ fontWeight: 600, fontSize: 13, color: '#374151', marginBottom: 4 }}>
          <i className="fa-solid fa-paperclip" style={{ marginRight: 6 }} />
          Proof of Account
          <span style={{ color: '#e53935', marginLeft: 2 }}>*</span>
          <span style={{ fontWeight: 400, color: '#9CA3AF', fontSize: 11, marginLeft: 6 }}>
            (Bank letter, cheque leaf, passbook copy, etc.)
          </span>
        </div>
        {hasError && (item._attachments ?? []).filter(a => !(a as any)._removed).length === 0 && (
          <div style={{ fontSize: 12, color: '#EF4444', marginBottom: 6 }}>
            <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 4 }} />
            At least one proof-of-account document is required.
          </div>
        )}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          {(item._attachments ?? []).filter(a => !(a as any)._removed).map((att, i) => (
            <div key={i} style={{
              display: 'flex', alignItems: 'center', gap: 8,
              background: '#F9FAFB', border: '1px solid #E5E7EB',
              borderRadius: 6, padding: '6px 10px', fontSize: 12,
            }}>
              <i className={`fa-solid ${(att.file_type || '').includes('pdf') ? 'fa-file-pdf' : 'fa-file-image'}`}
                style={{ color: '#6366F1', fontSize: 14 }} />
              <span style={{ flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                {att.file_name}
              </span>
              <span style={{ color: '#9CA3AF', flexShrink: 0 }}>
                {(att.file_size / 1024).toFixed(0)} KB
              </span>
              <BankAttachmentEditActions att={att} />
              <button
                type="button"
                onClick={() => {
                  const updated = (item._attachments ?? []).map((a, j) =>
                    j === i ? (a._file ? null : { ...a, _removed: true }) : a
                  ).filter(Boolean) as BankAttachment[];
                  onChange({ _attachments: updated });
                }}
                style={{ background: 'none', border: 'none', cursor: 'pointer', color: '#EF4444', padding: 2 }}
                title="Remove">
                <i className="fa-solid fa-xmark" />
              </button>
            </div>
          ))}
        </div>
        <label style={{
          display: 'inline-flex', alignItems: 'center', gap: 7,
          cursor: 'pointer', marginTop: 8,
          background: '#EEF2FF', color: '#4338CA',
          border: '1px dashed #C7D2FE', borderRadius: 7,
          padding: '7px 14px', fontSize: 12.5, fontWeight: 600,
        }}>
          <i className="fa-solid fa-upload" /> Attach Document
          <input
            type="file"
            accept="image/*,application/pdf"
            multiple
            style={{ display: 'none' }}
            onChange={e => {
              const files = Array.from(e.target.files ?? []);
              const newAtts: BankAttachment[] = files.map(f => ({
                file_name: f.name,
                file_type: f.type,
                file_size: f.size,
                storage_path: '',
                _file: f,
                _localUrl: URL.createObjectURL(f),
              }));
              onChange({ _attachments: [...(item._attachments ?? []), ...newAtts] });
              e.target.value = '';
            }}
          />
        </label>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// DraftBankItemCard — card in draft mode
// ─────────────────────────────────────────────────────────────────────────────

function DraftBankItemCard({ item, onUpdate, onToggleRemove, onToggleEdit, onSetPrimary, hidePencil = false, canRemove = true, canEditFields = true, employeeId }: {
  item: DraftBankItem;
  onUpdate: (update: Partial<DraftBankItem>) => void;
  onToggleRemove: () => void;
  onToggleEdit: () => void;
  onSetPrimary: () => void;
  hidePencil?: boolean;
  canRemove?: boolean;    // gates trash button (existing accounts only)
  canEditFields?: boolean; // gates the pencil/edit button
  employeeId: string;
}) {
  const amended   = isItemAmended(item);
  const isNew     = item._new && !item._removed;
  const isRemoved = item._removed;

  const borderColor = isRemoved
    ? '#E5E7EB'
    : item._hasError
    ? '#FCA5A5'
    : isNew
    ? '#34D399'
    : amended
    ? '#FCD34D'
    : '#6366F1';

  return (
    <div style={{
      border: `1.5px solid ${borderColor}`,
      borderRadius: 10, marginBottom: 12,
      background: '#fff', overflow: 'hidden',
      opacity: isRemoved ? 0.6 : 1,
    }}>
      {/* Header */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: 10,
        padding: '12px 14px',
        borderBottom: item._editing ? '1px solid #F3F4F6' : 'none',
      }}>
        <i className="fa-solid fa-building-columns"
          style={{ color: isRemoved ? '#9CA3AF' : '#6366F1', fontSize: 16, flexShrink: 0 }} />
        <div style={{ flex: 1, minWidth: 0 }}>
          {item.bank_name ? (
            <>
              <div style={{
                fontWeight: 600, fontSize: 14,
                color: isRemoved ? '#6B7280' : '#111827',
                textDecoration: isRemoved ? 'line-through' : 'none',
                overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
              }}>
                {item.bank_name}
              </div>
              {item.account_holder_name && (
                <div style={{ fontSize: 11.5, color: '#9CA3AF', marginTop: 1 }}>
                  {item.account_holder_name}
                  {item.account_number ? ` · ${maskAccount(item.account_number)}` : ''}
                </div>
              )}
            </>
          ) : (
            <div style={{ fontSize: 13, color: '#9CA3AF', fontStyle: 'italic' }}>
              New bank account — fill in details below
            </div>
          )}
        </div>

        {/* Badges */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 5, flexShrink: 0 }}>
          {item.is_primary && !isRemoved && (
            <span style={{ background: '#EEF2FF', color: '#4F46E5',
              borderRadius: 5, padding: '2px 7px', fontSize: 10, fontWeight: 700 }}>
              Primary
            </span>
          )}
          {isNew && !isRemoved && (
            <span style={{ background: '#ECFDF5', color: '#059669',
              borderRadius: 5, padding: '2px 7px', fontSize: 10, fontWeight: 700 }}>
              NEW
            </span>
          )}
          {amended && !isRemoved && (
            <span style={{ background: '#FFFBEB', color: '#D97706',
              borderRadius: 5, padding: '2px 7px', fontSize: 10, fontWeight: 700 }}>
              AMENDED
            </span>
          )}
          {isRemoved && (
            <span style={{ background: '#FEF2F2', color: '#DC2626',
              borderRadius: 5, padding: '2px 7px', fontSize: 10, fontWeight: 700 }}>
              REMOVED
            </span>
          )}
        </div>

        {/* Action buttons */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 4, flexShrink: 0 }}>
          {!isRemoved && !hidePencil && (item._new ? true : canEditFields) && (
            <button
              style={{
                ...iconBtnBase,
                borderColor: item._editing ? '#A5B4FC' : '#E5E7EB',
                color:       item._editing ? '#4F46E5' : '#6B7280',
                background:  item._editing ? '#EEF2FF' : 'none',
              }}
              title={item._editing ? 'Collapse' : 'Edit'}
              onClick={onToggleEdit}
              aria-label="Edit account">
              <i className="fa-solid fa-pen" style={{ fontSize: 12 }} />
            </button>
          )}
          {/* Show trash only when: new item (always removable) OR existing item with canRemove */}
          {(item._new || canRemove || isRemoved) && (
          <button
            style={{
              ...iconBtnBase,
              borderColor: isRemoved ? '#A5B4FC' : '#E5E7EB',
              color:       isRemoved ? '#4F46E5' : '#6B7280',
              background:  isRemoved ? '#EEF2FF' : 'none',
            }}
            title={isRemoved ? 'Restore' : 'Remove'}
            onClick={onToggleRemove}
            onMouseEnter={e => {
              if (!isRemoved) {
                (e.currentTarget as HTMLButtonElement).style.borderColor = '#FCA5A5';
                (e.currentTarget as HTMLButtonElement).style.color = '#DC2626';
                (e.currentTarget as HTMLButtonElement).style.background = '#FEF2F2';
              }
            }}
            onMouseLeave={e => {
              if (!isRemoved) {
                (e.currentTarget as HTMLButtonElement).style.borderColor = '#E5E7EB';
                (e.currentTarget as HTMLButtonElement).style.color = '#6B7280';
                (e.currentTarget as HTMLButtonElement).style.background = 'none';
              }
            }}
            aria-label={isRemoved ? 'Restore account' : 'Remove account'}>
            <i className={`fa-solid ${isRemoved ? 'fa-rotate-left' : 'fa-trash'}`}
              style={{ fontSize: 12 }} />
          </button>
          )}
        </div>
      </div>

      {/* Compact summary when collapsed and not removed */}
      {!item._editing && !isRemoved && item.bank_name && (
        <div style={{ padding: '8px 14px 10px' }}>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: '0 16px' }}>
            <FieldCell label="Country"  value={item.country_code || '—'} />
            <FieldCell label="Currency" value={item.currency_code || '—'} />
            <FieldCell label="Account"  value={item.account_number ? maskAccount(item.account_number) : '—'} mono />
          </div>
        </div>
      )}

      {/* Inline editor */}
      {item._editing && !isRemoved && (
        <DraftBankItemEditor
          item={item}
          onChange={onUpdate}
          onSetPrimary={onSetPrimary}
          hasError={item._hasError}
          employeeId={employeeId}
        />
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// BankPendingSetCard — amber ghost showing the proposed set when pendingCount > 0
// ─────────────────────────────────────────────────────────────────────────────

function BankPendingSetCard({ proposedData }: {
  proposedData: { employee_id: string; effective_from: string; items: Record<string, unknown>[] };
}) {
  const items = proposedData.items ?? [];

  function cell(label: string, value: unknown, mono?: boolean) {
    const display = value == null || value === '' ? '—' : String(value);
    return (
      <div style={{ padding: '5px 0', borderBottom: '1px solid #FDE68A' }}>
        <div style={{ fontSize: 10.5, color: '#92400E', marginBottom: 2, fontWeight: 500,
          textTransform: 'uppercase', letterSpacing: 0.5 }}>
          {label}
        </div>
        <div style={{ fontSize: 13, color: '#78350F', fontWeight: 500,
          fontFamily: mono ? 'monospace' : undefined }}>
          {display}
        </div>
      </div>
    );
  }

  return (
    <div style={{
      border: '1.5px solid #FCD34D', borderRadius: 10,
      marginBottom: 14, background: '#FFFBEB', overflow: 'hidden',
    }}>
      {/* Header */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: 10,
        padding: '12px 14px', borderBottom: '1px solid #FDE68A',
      }}>
        <i className="fa-solid fa-clock" style={{ color: '#D97706', fontSize: 16, flexShrink: 0 }} />
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontWeight: 600, fontSize: 14, color: '#78350F' }}>
            Bank Account Update — Pending Approval
          </div>
          <div style={{ fontSize: 11.5, color: '#92400E', marginTop: 1 }}>
            Effective {fmtDate(proposedData.effective_from)}
            {' · '}{items.length} account{items.length !== 1 ? 's' : ''} in proposed set
          </div>
        </div>
        <span style={{
          background: '#FEF3C7', color: '#92400E',
          borderRadius: 5, padding: '2px 8px',
          fontSize: 11, fontWeight: 700, flexShrink: 0,
        }}>
          Pending Approval
        </span>
      </div>

      {/* Proposed items */}
      <div style={{ padding: '10px 14px 14px', display: 'flex', flexDirection: 'column', gap: 8 }}>
        {items.map((it, idx) => {
          const rules = getRules(String(it.country_code ?? ''));
          return (
            <div key={idx} style={{
              border: '1px solid #FDE68A', borderRadius: 8,
              padding: '10px 12px', background: '#FFFDE7',
            }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 8 }}>
                <i className="fa-solid fa-building-columns"
                  style={{ color: '#D97706', fontSize: 14, flexShrink: 0 }} />
                <div style={{ fontWeight: 600, fontSize: 13, color: '#78350F', flex: 1 }}>
                  {String(it.bank_name ?? 'Bank account')}
                </div>
                {it.is_primary && (
                  <span style={{ background: '#FEF3C7', color: '#92400E',
                    borderRadius: 4, padding: '1px 6px', fontSize: 10, fontWeight: 700 }}>
                    Primary
                  </span>
                )}
              </div>
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: '0 12px' }}>
                {cell('Account Holder', it.account_holder_name)}
                {cell('Account Number', it.account_number ? maskAccount(String(it.account_number)) : '—', true)}
                {cell('Country', it.country_code)}
                {cell('Currency', it.currency_code)}
                {rules.branchName !== 'hidden' && it.branch_name && cell('Branch', it.branch_name)}
                {rules.branchCode !== 'hidden' && it.branch_code && cell('Branch Code', it.branch_code, true)}
                {rules.ifsc !== 'hidden' && it.ifsc_code && cell('IFSC', it.ifsc_code, true)}
                {rules.iban !== 'hidden' && it.iban && cell('IBAN', it.iban, true)}
                {it.swift_bic && cell('SWIFT / BIC', it.swift_bic, true)}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// BankSetHistoryPanel — set-level history loaded lazily
// ─────────────────────────────────────────────────────────────────────────────

function BankSetHistoryPanel({ employeeId }: { employeeId: string }) {
  const [sets,    setSets]    = useState<BankSetHistoryRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [err,     setErr]     = useState('');
  const [expandedSetId, setExpandedSetId] = useState<string | null>(null);
  const loaded = useRef(false);

  useEffect(() => {
    if (loaded.current) return;
    loaded.current = true;
    setLoading(true);
    supabase.rpc('get_employee_bank_account_set_history', { p_employee_id: employeeId })
      .then(({ data, error }) => {
        if (error) { setErr(error.message); return; }
        const payload = data as { ok: boolean; sets: BankSetHistoryRow[] } | null;
        setSets(payload?.sets ?? []);
      })
      .finally(() => setLoading(false));
  }, [employeeId]);

  if (loading) return (
    <div style={{ textAlign: 'center', padding: '16px 0', color: '#9CA3AF', fontSize: 13 }}>
      <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Loading history…
    </div>
  );

  if (err) return (
    <div style={{ color: '#DC2626', fontSize: 13, padding: '10px 0' }}>
      <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 6 }} />{err}
    </div>
  );

  if (sets.length === 0) return (
    <div style={{ color: '#9CA3AF', fontSize: 13, padding: '10px 0', textAlign: 'center' }}>
      No prior sets on record.
    </div>
  );

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
      {sets.map((set, idx) => {
        const isExpanded = expandedSetId === set.set_id;
        const isCurrent = idx === 0 && set.is_active;

        return (
          <div key={set.set_id} style={{
            border: '1px solid #E5E7EB', borderRadius: 8, overflow: 'hidden',
          }}>
            <button
              style={{
                width: '100%', textAlign: 'left',
                padding: '10px 14px', background: isExpanded ? '#F5F3FF' : '#FAFAFA',
                border: 'none', cursor: 'pointer',
                display: 'flex', alignItems: 'center', gap: 10,
              }}
              onClick={() => setExpandedSetId(isExpanded ? null : set.set_id)}>
              <i className="fa-solid fa-layer-group"
                style={{ color: '#6366F1', fontSize: 14, flexShrink: 0 }} />
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontWeight: 600, fontSize: 13, color: '#111827' }}>
                  {fmtDate(set.effective_from)}{' → '}{fmtDate(set.effective_to)}
                </div>
                <div style={{ fontSize: 11.5, color: '#9CA3AF', marginTop: 1 }}>
                  {set.item_count} account{set.item_count !== 1 ? 's' : ''}
                </div>
              </div>
              {isCurrent && (
                <span style={{ background: '#EEF2FF', color: '#4F46E5',
                  borderRadius: 10, padding: '1px 8px', fontSize: 10, fontWeight: 700 }}>
                  Current
                </span>
              )}
              <i className={`fa-solid ${isExpanded ? 'fa-chevron-up' : 'fa-chevron-down'}`}
                style={{ color: '#9CA3AF', fontSize: 11 }} />
            </button>

            {isExpanded && set.items && set.items.length > 0 && (
              <div style={{ padding: '10px 14px', background: '#fff', borderTop: '1px solid #F3F4F6' }}>
                {set.items.map((item, i) => (
                  <div key={i} style={{
                    padding: '8px 0', borderBottom: '1px solid #F9FAFB',
                    display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: '0 16px',
                  }}>
                    <FieldCell label="Bank"           value={item.bank_name} />
                    <FieldCell label="Account Holder" value={item.account_holder_name} />
                    <FieldCell label="Account Number" value={maskAccount(item.account_number)} mono />
                  </div>
                ))}
              </div>
            )}

            {isExpanded && (!set.items || set.items.length === 0) && (
              <div style={{ padding: '10px 14px', color: '#9CA3AF', fontSize: 13 }}>
                No items in this set.
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Main Portlet
// ─────────────────────────────────────────────────────────────────────────────

export default function BankAccountsPortlet({
  employeeId,
  hireDate,
  isNewHire = false,
  readOnly = false,
  canCreate = true,
  canEdit = true,
  canDelete = true,
  pendingCount = 0,
  isBankException = false,
  editMode = false,
  onChanged,
  onAccountCountChange,
  saveTriggerRef,
  saveAllRef,
  reviewMode = false,
  sectionTitle,
}: BankAccountsPortletProps) {
  const { picklistValues } = usePicklistValues();

  // Stable ref so loadCurrentSet can call the latest onAccountCountChange
  // without needing it in useCallback deps (which would cause an infinite loop).
  const onAccountCountChangeRef = useRef(onAccountCountChange);
  useEffect(() => { onAccountCountChangeRef.current = onAccountCountChange; }, [onAccountCountChange]);

  // ── Server state ──────────────────────────────────────────────────────────
  const [currentSet,   setCurrentSet]   = useState<BankSetInfo | null>(null);
  const [currentItems, setCurrentItems] = useState<BankSetItem[]>([]);
  const [loading,      setLoading]      = useState(true);
  const [loadErr,      setLoadErr]      = useState('');

  // ── Pending set preview ───────────────────────────────────────────────────
  const [pendingChangeData, setPendingChangeData] = useState<{
    employee_id: string; effective_from: string; items: Record<string, unknown>[];
  } | null>(null);

  // ── UI state ──────────────────────────────────────────────────────────────
  const [mode,               setMode]               = useState<'view' | 'draft'>('view');
  const [draftItems,         setDraftItems]         = useState<DraftBankItem[]>([]);
  const [draftEffectiveFrom, setDraftEffectiveFrom] = useState(firstOfCurrentMonth());
  const [submitting,         setSubmitting]         = useState(false);
  const [submitError,        setSubmitError]        = useState('');
  const [workflowPending,    setWorkflowPending]    = useState(false);
  const [showHistory,        setShowHistory]        = useState(false);

  // ── Load active set ───────────────────────────────────────────────────────
  const loadCurrentSet = useCallback(async () => {
    if (!employeeId) return;
    setLoading(true); setLoadErr('');
    const { data, error } = await supabase.rpc('get_employee_bank_account_set', {
      p_employee_id: employeeId,
    });
    if (error) { setLoadErr(error.message); setLoading(false); return; }
    const payload = data as { ok: boolean; set: BankSetInfo | null; items: BankSetItem[] } | null;
    const items = payload?.items ?? [];
    setCurrentSet(payload?.set ?? null);
    setCurrentItems(items);
    setLoading(false);
    onAccountCountChangeRef.current?.(items.length > 0);
  }, [employeeId]); // onAccountCountChange intentionally excluded — it's a callback, not a fetch dependency

  useEffect(() => { loadCurrentSet(); }, [loadCurrentSet]);

  // ── Fetch pending proposed_data when pendingCount > 0 ────────────────────
  useEffect(() => {
    if (pendingCount === 0) { setPendingChangeData(null); return; }
    if (!employeeId) return;
    let cancelled = false;
    supabase
      .from('workflow_pending_changes')
      .select('proposed_data')
      .eq('module_code', 'profile_bank')
      .eq('status', 'pending')
      .eq('proposed_data->>employee_id', employeeId)
      .order('created_at', { ascending: false })
      .limit(1)
      .then(({ data }) => {
        if (cancelled || !data || data.length === 0) return;
        setPendingChangeData(
          (data[0] as any).proposed_data as {
            employee_id: string; effective_from: string; items: Record<string, unknown>[];
          }
        );
      });
    return () => { cancelled = true; };
  }, [pendingCount, employeeId]);

  // ── Auto-enter draft for new hire / editMode ──────────────────────────────
  // editMode=true (approver clicked Update): always open in edit regardless of
  // whether accounts exist — same behaviour as all other portlets.
  // isNewHire only (hire wizard tab): only auto-enter draft when no accounts
  // saved yet; once saved, land on view so the user sees their data first.
  const autoEnteredRef = useRef(false);
  useEffect(() => {
    if (autoEnteredRef.current || loading || picklistValues.length === 0) return;
    if (editMode || (isNewHire && currentItems.length === 0)) {
      autoEnteredRef.current = true;
      enterDraft();
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [loading, isNewHire, editMode, picklistValues.length, currentItems.length]);

  // ── reviewMode: stay in view unless editMode is explicitly true ──────────
  // Runs on every change to editMode, reviewMode, or mode so it catches both:
  //   (a) the portlet auto-entering draft after load (isNewHire=true) while
  //       editMode is still false — discards immediately back to view
  //   (b) the Cancel button clearing editingSections (editMode→false) — discards
  // discardDraft() already resets autoEnteredRef, enabling re-entry on Update.
  useEffect(() => {
    if (reviewMode && !editMode && mode === 'draft') {
      discardDraft();
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [editMode, reviewMode, mode]);

  // ── Cutoff check ──────────────────────────────────────────────────────────
  const dayOfMonth = new Date().getDate();
  const submissionClosed = !isBankException && !isNewHire && dayOfMonth > 15;

  // ── Draft management ──────────────────────────────────────────────────────

  function itemToDraft(item: BankSetItem): DraftBankItem {
    const ISO_TO_REF: Record<string, string> = Object.fromEntries(
      Object.entries(REF_TO_ISO).map(([ref, iso]) => [iso, ref])
    );
    const targetRef = ISO_TO_REF[item.country_code] ?? '';
    const countryPv = picklistValues.find(
      p => p.picklistId === 'ID_COUNTRY' && p.refId === targetRef
    );
    const countryPvId = countryPv ? String(countryPv.id) : '';

    const banks = countryPv
      ? picklistValues.filter(
          p => p.picklistId === 'BANK' && p.parentValueId === countryPv.id && p.active !== false
        )
      : [];
    const bankPv = banks.find((b: any) => b.value === item.bank_name);
    const bankPvId = bankPv ? String(bankPv.id) : '';

    const existingAttachments = ((item as any).attachments ?? []) as BankAttachment[];
    const original = {
      country_code: item.country_code,
      currency_code: item.currency_code,
      bank_name: item.bank_name,
      branch_name: item.branch_name ?? '',
      branch_code: item.branch_code ?? '',
      account_holder_name: item.account_holder_name,
      account_number: item.account_number,
      ifsc_code: item.ifsc_code ?? '',
      iban: item.iban ?? '',
      swift_bic: item.swift_bic ?? '',
      is_primary: item.is_primary,
      attachmentCount: existingAttachments.length,
    };

    return {
      _localId: randomUUID(),
      bank_account_group_id: item.bank_account_group_id,
      ...original,
      _countryPvId: countryPvId,
      _bankPvId: bankPvId,
      _new: false,
      _removed: false,
      _editing: false,
      _hasError: false,
      _errors: {},
      _attachments: (item as any).attachments ?? [],
      _original: original,
    };
  }

  function enterDraft(autoEditIdx?: number) {
    // Hire wizard: use the exact hire date so the bank set's effective_from
    // matches the employee's hire date (not the 1st of the hire month).
    // Active-employee edits keep the first-of-month convention.
    const defaultEffFrom = isNewHire && hireDate
      ? hireDate.slice(0, 10)
      : firstOfCurrentMonth();
    setDraftItems(currentItems.map((item, idx) => ({
      ...itemToDraft(item),
      // In review mode all cards expand; otherwise auto-open only the clicked card.
      _editing: reviewMode ? true : (autoEditIdx !== undefined ? idx === autoEditIdx : false),
    })));
    setDraftEffectiveFrom(defaultEffFrom);
    setSubmitError('');
    setMode('draft');
  }

  function discardDraft() {
    setDraftItems([]);
    setSubmitError('');
    setMode('view');
    autoEnteredRef.current = false;
  }

  function addItem() {
    setDraftItems(prev => [...prev, {
      _localId: randomUUID(),
      bank_account_group_id: null,
      country_code: '', currency_code: '', bank_name: '',
      branch_name: '', branch_code: '', account_holder_name: '',
      account_number: '', ifsc_code: '', iban: '', swift_bic: '',
      is_primary: prev.filter(i => !i._removed).length === 0, // auto-primary if first active
      _countryPvId: '', _bankPvId: '',
      _new: true, _removed: false, _editing: true,
      _hasError: false, _errors: {},
      _attachments: [],
      _original: null,
    }]);
  }

  function updateDraftItem(localId: string, update: Partial<DraftBankItem>) {
    setDraftItems(prev =>
      prev.map(item => item._localId === localId ? { ...item, ...update } : item)
    );
  }

  function setPrimary(localId: string) {
    setDraftItems(prev =>
      prev.map(item => ({
        ...item,
        is_primary: item._localId === localId,
      }))
    );
  }

  function toggleRemove(localId: string) {
    setDraftItems(prev =>
      prev.map(item =>
        item._localId === localId
          ? { ...item, _removed: !item._removed, _editing: false, _hasError: false }
          : item
      )
    );
  }

  function toggleEdit(localId: string) {
    setDraftItems(prev =>
      prev.map(item =>
        item._localId === localId ? { ...item, _editing: !item._editing } : item
      )
    );
  }

  // ── Submit ────────────────────────────────────────────────────────────────
  async function handleSubmit(): Promise<boolean> {
    const active = draftItems.filter(i => !i._removed);

    // No accounts and never had any — nothing to write
    if (active.length === 0 && currentItems.length === 0) return true;

    // Hire-flow guard: employee not yet active — an empty active set during hire
    // means no accounts to add. Never submit an empty set for a new hire.
    if (active.length === 0 && isNewHire) return true;

    // Attachment validation — must run before the "no changes" guard so existing
    // accounts without a proof-of-account are also caught.
    const missingAttachment = active.some(
      i => (i._attachments ?? []).filter(a => !(a as any)._removed).length === 0
    );
    if (missingAttachment) {
      setDraftItems(draftItems.map(i =>
        !i._removed && (i._attachments ?? []).filter(a => !(a as any)._removed).length === 0
          ? { ...i, _hasError: true, _errors: { ...i._errors, attachment: 'Proof of account is required.' }, _editing: true }
          : i
      ));
      setSubmitError('Please attach a proof-of-account document for each bank account.');
      return false;
    }

    // No changes — skip the write
    const hasAdded   = draftItems.some(i => i._new && !i._removed);
    const hasRemoved = draftItems.some(i => i._removed && !i._new);
    const hasAmended = draftItems.some(i => !i._new && !i._removed && isItemAmended(i));
    if (!hasAdded && !hasRemoved && !hasAmended) return true;

    // Validate
    const primaryCount = active.filter(i => i.is_primary).length;
    const withErrors = draftItems.map(item => {
      if (item._removed) return { ...item, _hasError: false, _errors: {} };
      const rules = getRules(item.country_code);
      const errs: Record<string, string> = {};
      if (!item._countryPvId)            errs.country = 'Country is required.';
      if (!item.bank_name.trim())        errs.bankName = 'Bank name is required.';
      if (!item.account_holder_name.trim()) errs.accountHolder = 'Account holder is required.';
      if (!item.account_number.trim())   errs.accountNumber = 'Account number is required.';
      if (rules.branchName === 'mandatory' && !item.branch_name.trim()) errs.branchName = 'Branch name is required.';
      if (rules.branchCode === 'mandatory' && !item.branch_code.trim()) errs.branchCode = 'Branch code is required.';
      if (rules.ifsc === 'mandatory'     && !item.ifsc_code.trim())     errs.ifscCode = 'IFSC is required.';
      if (rules.iban === 'mandatory'     && !item.iban.trim())          errs.iban = 'IBAN is required.';
      // Proof of account attachment is mandatory
      const activeAttachments = (item._attachments ?? []).filter(a => !(a as any)._removed);
      if (activeAttachments.length === 0) errs.attachment = 'Proof of account is required.';
      // Primary is validated at set level — flag the item only if NO item has primary and this is the only active one
      const hasError = Object.keys(errs).length > 0;
      return { ...item, _hasError: hasError, _errors: errs };
    });

    if (withErrors.some(i => i._hasError)) {
      setDraftItems(withErrors.map(i => ({
        ...i,
        _editing: i._hasError ? true : i._editing,
      })));
      setSubmitError('Please fix the highlighted errors before submitting.');
      return false;
    }

    if (primaryCount !== 1) {
      setSubmitError(
        primaryCount === 0
          ? 'Please mark one account as the primary account.'
          : 'Only one account can be marked as primary.'
      );
      return false;
    }

    setSubmitting(true);
    setSubmitError('');

    try {
      // ── Upload staged attachment files to storage ──────────────────────
      // Storage path: bank-accounts/{employee_id}/{localId}/{filename}
      // localId is a temporary key — the RPC assigns the real group_id on insert.
      const HR_BUCKET = 'hr-attachments';
      const itemsWithUploads = await Promise.all(active.map(async item => {
        const uploaded: BankAttachment[] = [];
        for (const att of item._attachments ?? []) {
          if ((att as any)._removed) continue;
          if (att._file) {
            // New file — upload to storage
            const ext = att.file_name.split('.').pop() ?? 'bin';
            const path = `bank-accounts/${employeeId}/${item._localId}/${randomUUID()}.${ext}`;
            const { error: upErr } = await supabase.storage
              .from(HR_BUCKET)
              .upload(path, att._file, { contentType: att.file_type, upsert: false });
            if (upErr) throw new Error(`Upload failed for ${att.file_name}: ${upErr.message}`);
            uploaded.push({ file_name: att.file_name, file_type: att.file_type, file_size: att.file_size, storage_path: path });
          } else if (att.storage_path) {
            // Existing DB attachment — pass through
            uploaded.push({ file_name: att.file_name, file_type: att.file_type, file_size: att.file_size, storage_path: att.storage_path });
          }
        }
        return { item, attachments: uploaded };
      }));

      const submitItems = itemsWithUploads.map(({ item, attachments }) => ({
        bank_account_group_id: item.bank_account_group_id,  // null for new
        country_code:          item.country_code,
        currency_code:         item.currency_code,
        bank_name:             item.bank_name.trim(),
        branch_name:           item.branch_name.trim() || null,
        branch_code:           item.branch_code.trim() || null,
        account_holder_name:   item.account_holder_name.trim(),
        account_number:        item.account_number.trim(),
        ifsc_code:             item.ifsc_code.trim() || null,
        iban:                  item.iban.trim() || null,
        swift_bic:             item.swift_bic.trim() || null,
        is_primary:            item.is_primary,
        attachments,
      }));

      // Flatten all attachments for the p_attachments param (RPC links them by position)
      const allAttachments = itemsWithUploads.flatMap(({ attachments }) => attachments);

      const { data, error: rpcErr } = await supabase.rpc('submit_bank_account_set', {
        p_employee_id:    employeeId,
        p_effective_from: draftEffectiveFrom,
        p_items:          submitItems,
        p_attachments:    allAttachments,
      });

      if (rpcErr) throw new Error(rpcErr.message);
      const result = data as {
        ok: boolean; workflow: boolean;
        instance_id?: string; set_id?: string;
        effective_from: string; change_summary: string;
      } | null;
      if (!result?.ok) throw new Error('Submit failed.');

      if (result.workflow) {
        setWorkflowPending(true);
      } else {
        onChanged?.();
      }
      setMode('view');
      await loadCurrentSet();
      return true;

    } catch (err: any) {
      setSubmitError(err.message ?? 'An unexpected error occurred.');
      return false;
    } finally {
      setSubmitting(false);
    }
  }

  // Keep ref always pointing to the latest handleSubmit
  const handleSubmitRef = useRef(handleSubmit);
  useEffect(() => { handleSubmitRef.current = handleSubmit; });

  // Wire saveTriggerRef (hire wizard)
  useEffect(() => {
    if (!saveTriggerRef) return;
    saveTriggerRef.current = () => handleSubmitRef.current();
    return () => { saveTriggerRef.current = null; };
  }, [saveTriggerRef]);

  // Wire saveAllRef (editMode compat for EmployeeEditPanel)
  useEffect(() => {
    if (!saveAllRef) return;
    saveAllRef.current = () => handleSubmitRef.current();
    return () => { saveAllRef.current = null; };
  }, [saveAllRef]);

  // ── Draft counters ────────────────────────────────────────────────────────
  const added     = draftItems.filter(i => i._new    && !i._removed).length;
  const removed   = draftItems.filter(i => i._removed && !i._new).length;
  const amended   = draftItems.filter(i => !i._new && !i._removed && isItemAmended(i)).length;
  const unchanged = draftItems.filter(i => !i._new && !i._removed && !isItemAmended(i)).length;
  const hasDraftChanges = added > 0 || removed > 0 || amended > 0;

  // ── Loading / error ───────────────────────────────────────────────────────
  if (loading) return (
    <div style={{ textAlign: 'center', padding: '24px 0', color: '#9CA3AF' }}>
      <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Loading bank accounts…
    </div>
  );

  if (loadErr) return (
    <div style={{ color: '#DC2626', fontSize: 13, padding: '10px 0' }}>
      <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 6 }} />{loadErr}
    </div>
  );

  // ── Render ────────────────────────────────────────────────────────────────
  // ── Buttons rendered in the section header (when sectionTitle prop is provided) ──
  // Personal Info-style button styles (consistent across all portlets)
  const histBtnStyle = (active: boolean): React.CSSProperties => ({
    background: active ? '#EEF2FF' : 'none',
    border: `1px solid ${active ? '#A5B4FC' : '#E5E7EB'}`,
    borderRadius: 6, padding: '4px 8px', cursor: 'pointer',
    color: active ? '#4F46E5' : '#6B7280', fontSize: 12,
    display: 'inline-flex', alignItems: 'center', gap: 4,
  });
  const editBtnStyle: React.CSSProperties = {
    display: 'inline-flex', alignItems: 'center', gap: 5,
    padding: '5px 14px', borderRadius: 6, cursor: 'pointer',
    border: '1px solid #D1D5DB', background: '#F9FAFB',
    fontSize: 12, fontWeight: 600, color: '#374151',
  };

  const historyBtn = !isNewHire ? (
    <button
      style={histBtnStyle(showHistory)}
      onClick={() => setShowHistory(p => !p)}
      title={showHistory ? 'Close history' : 'View history'}
    >
      <i className="fa-solid fa-clock-rotate-left" style={{ fontSize: 11 }} />
      {showHistory ? 'Close' : 'History'}
    </button>
  ) : null;

  const editBtn = (canCreate || canEdit || canDelete) && !readOnly && !reviewMode && pendingCount === 0 && !submissionClosed ? (
    <button style={editBtnStyle} onClick={enterDraft}>
      <i className="fa-solid fa-pen" style={{ fontSize: 11 }} />
      Edit
    </button>
  ) : null;

  return (
    <div>
      {/* ── Section header — title + action buttons in one row (Personal Info pattern) ── */}
      {sectionTitle && (
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 14 }}>
          <div className="ev-section-title" style={{ display: 'flex', alignItems: 'flex-start', flexDirection: 'column', gap: 6 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <i className={`fa-solid ${sectionTitle.icon}`} /> {sectionTitle.text}
              {(sectionTitle.pending ?? 0) > 0 && (
                <span style={{
                  display: 'inline-flex', alignItems: 'center', gap: 4,
                  background: '#FEF3C7', color: '#B45309', border: '1px solid #F59E0B',
                  borderRadius: 10, padding: '2px 8px', fontSize: 11, fontWeight: 600, lineHeight: 1.4,
                }}>
                  <i className="fa-solid fa-hourglass-half" style={{ fontSize: 10 }} />
                  Workflow Pending Approval
                </span>
              )}
            </div>
            {(sectionTitle.pending ?? 0) > 0 && sectionTitle.onViewProgress && (
              <button
                onClick={sectionTitle.onViewProgress}
                style={{ background: 'none', border: 'none', padding: 0, cursor: 'pointer',
                  color: '#6366F1', fontSize: 12, fontWeight: 500, textDecoration: 'underline' }}
              >
                View progress
              </button>
            )}
          </div>
          {mode === 'view' && historyBtn && (
            <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
              {historyBtn}
            </div>
          )}
        </div>
      )}

      {/* Submission cutoff banner — visible in view mode, after 15th, non-exempt ESS */}
      {submissionClosed && mode === 'view' && pendingCount === 0 && (
        <div style={{
          display: 'flex', alignItems: 'center', gap: 10,
          background: '#FFF7ED', border: '1px solid #FED7AA',
          borderRadius: 8, padding: '10px 14px', marginBottom: 14, fontSize: 13,
        }}>
          <i className="fa-solid fa-calendar-xmark" style={{ color: '#C2410C', fontSize: 15 }} />
          <span style={{ flex: 1, color: '#7C2D12' }}>
            <strong>Submission window closed.</strong> Bank account changes can only be submitted
            on or before the 15th of the month. Changes can be made from the 1st of next month.
          </span>
        </div>
      )}

      {/* Post-submit workflow-pending banner */}
      {workflowPending && pendingCount === 0 && (
        <div style={{
          display: 'flex', alignItems: 'center', gap: 10,
          background: '#FFFBEB', border: '1px solid #FCD34D',
          borderRadius: 8, padding: '10px 14px', marginBottom: 14, fontSize: 13,
        }}>
          <i className="fa-solid fa-clock" style={{ color: '#D97706', fontSize: 15 }} />
          <span style={{ flex: 1, color: '#92400E' }}>
            <strong>Submitted for approval</strong> — your bank account change is pending review.
            You'll be notified once it's approved.
          </span>
          <button
            onClick={() => { setWorkflowPending(false); loadCurrentSet(); }}
            style={{ background: 'none', border: 'none', cursor: 'pointer', color: '#92400E', padding: 2 }}
            title="Dismiss">
            <i className="fa-solid fa-xmark" />
          </button>
        </div>
      )}

      {/* ── VIEW MODE ─────────────────────────────────────────────────────── */}
      {mode === 'view' && (
        <>
          {/* Pending set preview — replaces normal view when a change is in flight */}
          {pendingCount > 0 && pendingChangeData && (
            <BankPendingSetCard proposedData={pendingChangeData} />
          )}

          {/* Empty state (no pending, no accounts) */}
          {currentItems.length === 0 && pendingCount === 0 && (
            <div style={{ textAlign: 'center', padding: '24px 0', color: '#9CA3AF', fontSize: 13 }}>
              <i className="fa-solid fa-building-columns"
                style={{ display: 'block', fontSize: 28, marginBottom: 8, color: '#E5E7EB' }} />
              No bank accounts on file.
            </div>
          )}

          {/* Active set info chip */}
          {currentSet && currentItems.length > 0 && !isNewHire && (
            <div style={{ marginBottom: 10, fontSize: 12, color: '#6B7280',
              display: 'flex', alignItems: 'center', gap: 6 }}>
              <i className="fa-solid fa-calendar-check" style={{ color: '#6366F1' }} />
              Effective {fmtDate(currentSet.effective_from)}
            </div>
          )}

          {/* Account cards — pencil icon in each card header triggers edit */}
          {currentItems.map((item, idx) => (
            <BankViewCard key={item.bank_account_group_id} item={item}
              effectiveFrom={currentSet?.effective_from}
              isNewHire={isNewHire}
              onEdit={editBtn ? () => enterDraft(idx) : undefined} />
          ))}

          {/* History button only (edit moved into card header) */}
          {!sectionTitle && historyBtn && (
            <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 6, marginBottom: 12 }}>
              {historyBtn}
            </div>
          )}

          {!isNewHire && showHistory && (
            <div style={{ marginTop: 10 }}>
              <BankSetHistoryPanel employeeId={employeeId} />
            </div>
          )}
        </>
      )}

      {/* ── DRAFT MODE ────────────────────────────────────────────────────── */}
      {mode === 'draft' && (
        <>
          {/* Draft header: effective_from + change counter — hidden in hire wizard (isNewHire) */}
          {!isNewHire && <div style={{
            background: '#F5F3FF', border: '1px solid #C7D2FE',
            borderRadius: 8, padding: '12px 16px', marginBottom: 14,
            display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 12,
          }}>
            {!isNewHire && (
              <div style={{ flex: 1, minWidth: 200 }}>
                <div style={{ fontSize: 11, fontWeight: 600, color: '#4338CA',
                  textTransform: 'uppercase', letterSpacing: 0.4, marginBottom: 4 }}>
                  Effective From
                </div>
                {/* ESS non-exempt: locked to 1st of current month, display only */}
                {!isBankException ? (
                  <>
                    <div style={{ fontSize: 13, fontWeight: 600, color: '#111827' }}>
                      {fmtDate(draftEffectiveFrom)}
                    </div>
                    <div style={{ fontSize: 11, color: '#6366F1', marginTop: 3 }}>
                      <i className="fa-solid fa-circle-info" style={{ marginRight: 4 }} />
                      Applied from 1st of {fmtMonthYear(draftEffectiveFrom)}
                    </div>
                  </>
                ) : (
                  <>
                    <input
                      type="date" min="1900-01-01" max="2100-12-31" min="1900-01-01" max="2100-12-31"
                      value={draftEffectiveFrom}
                      style={{
                        fontSize: 13, padding: '5px 8px', borderRadius: 6,
                        border: '1px solid #C7D2FE', color: '#111827', background: '#fff',
                      }}
                      onChange={e => {
                        if (!e.target.value) return;
                        const snapped = snapToFirstOfMonth(e.target.value);
                        const hireMin = hireDate ? snapToFirstOfMonth(hireDate.slice(0, 10)) : null;
                        setDraftEffectiveFrom(hireMin && snapped < hireMin ? hireMin : snapped);
                      }}
                    />
                    <div style={{ fontSize: 11, color: '#6366F1', marginTop: 3 }}>
                      <i className="fa-solid fa-circle-info" style={{ marginRight: 4 }} />
                      Applied from 1st of {fmtMonthYear(snapToFirstOfMonth(draftEffectiveFrom))}
                    </div>
                  </>
                )}
              </div>
            )}

            {/* Change counter */}
            {hasDraftChanges && (
              <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                {added > 0 && (
                  <span style={{ background: '#ECFDF5', color: '#059669',
                    borderRadius: 6, padding: '3px 10px', fontSize: 11.5, fontWeight: 600 }}>
                    +{added} added
                  </span>
                )}
                {amended > 0 && (
                  <span style={{ background: '#FFFBEB', color: '#D97706',
                    borderRadius: 6, padding: '3px 10px', fontSize: 11.5, fontWeight: 600 }}>
                    {amended} amended
                  </span>
                )}
                {removed > 0 && (
                  <span style={{ background: '#FEF2F2', color: '#DC2626',
                    borderRadius: 6, padding: '3px 10px', fontSize: 11.5, fontWeight: 600 }}>
                    −{removed} removed
                  </span>
                )}
                {unchanged > 0 && (
                  <span style={{ background: '#F3F4F6', color: '#6B7280',
                    borderRadius: 6, padding: '3px 10px', fontSize: 11.5 }}>
                    {unchanged} unchanged
                  </span>
                )}
              </div>
            )}
          </div>}

          {/* Empty draft state */}
          {draftItems.length === 0 && (
            <div style={{ textAlign: 'center', padding: '20px 0', color: '#9CA3AF', fontSize: 13 }}>
              <i className="fa-solid fa-building-columns"
                style={{ display: 'block', fontSize: 26, marginBottom: 8, color: '#E5E7EB' }} />
              No accounts — click "Add Account" to begin.
            </div>
          )}

          {/* Draft item cards */}
          {draftItems.map(item => (
            <DraftBankItemCard
              key={item._localId}
              item={item}
              onUpdate={update => updateDraftItem(item._localId, update)}
              onToggleRemove={() => toggleRemove(item._localId)}
              onToggleEdit={() => toggleEdit(item._localId)}
              onSetPrimary={() => setPrimary(item._localId)}
              hidePencil={reviewMode}
              canRemove={item._new ? true : canDelete}
              canEditFields={item._new ? true : canEdit}
              employeeId={employeeId}
            />
          ))}

          {/* Add Account — gated by canCreate */}
          {canCreate && (
            <button className="emp-btn-secondary"
              style={{ marginTop: 4, padding: '7px 18px', fontSize: 13 }}
              onClick={addItem}>
              <i className="fa-solid fa-plus" style={{ marginRight: 6 }} />Add Account
            </button>
          )}

          {/* Error banner */}
          {submitError && (
            <div style={{
              background: '#FEF2F2', border: '1px solid #FECACA',
              borderRadius: 7, padding: '8px 12px', color: '#DC2626',
              fontSize: 12.5, marginTop: 14,
            }}>
              <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 6 }} />
              {submitError}
            </div>
          )}

          {/* Footer: Submit + Discard — hidden in hire-wizard isNewHire mode */}
          {!isNewHire && (
            <div style={{ display: 'flex', gap: 10, marginTop: 18, paddingTop: 14,
              borderTop: '1px solid #F3F4F6' }}>
              <button
                className="emp-btn-primary"
                style={{ padding: '8px 22px', fontSize: 13 }}
                disabled={submitting}
                onClick={handleSubmit}>
                {submitting
                  ? <><i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />Submitting…</>
                  : <><i className="fa-solid fa-check" style={{ marginRight: 6 }} />Submit Changes</>
                }
              </button>
              <button
                className="emp-btn-ghost"
                style={{ padding: '8px 18px', fontSize: 13 }}
                disabled={submitting}
                onClick={discardDraft}>
                Discard Changes
              </button>
            </div>
          )}
        </>
      )}
    </div>
  );
}
