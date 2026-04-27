import { useState, useMemo, useEffect, useRef } from 'react';
import ConfirmationModal from '../shared/ConfirmationModal';
import ErrorBanner from '../shared/ErrorBanner';
import { useExchangeRates } from '../../hooks/useExchangeRates';
import { useCurrencies } from '../../hooks/useCurrencies';
import { usePicklistValues } from '../../hooks/usePicklistValues';

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

interface StoredRate {
  id: string;
  fromCode: string;
  toCode: string;
  rate: number;
  effectiveDate: string;
}

interface PicklistItem {
  id: string; picklistId: string; value: string; active?: boolean;
  meta?: { code?: string; symbol?: string; };
}

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

const CURRENCY_FLAGS: Record<string, string> = {
  AED:'🇦🇪', AFN:'🇦🇫', AUD:'🇦🇺', BDT:'🇧🇩', BHD:'🇧🇭',
  BRL:'🇧🇷', CAD:'🇨🇦', CHF:'🇨🇭', CNY:'🇨🇳', CZK:'🇨🇿',
  DKK:'🇩🇰', EGP:'🇪🇬', EUR:'🇪🇺', GBP:'🇬🇧', GHS:'🇬🇭',
  HKD:'🇭🇰', IDR:'🇮🇩', ILS:'🇮🇱', INR:'🇮🇳', IQD:'🇮🇶',
  JOD:'🇯🇴', JPY:'🇯🇵', KES:'🇰🇪', KHR:'🇰🇭', KRW:'🇰🇷',
  KWD:'🇰🇼', LBP:'🇱🇧', LKR:'🇱🇰', MMK:'🇲🇲', MXN:'🇲🇽',
  MYR:'🇲🇾', NGN:'🇳🇬', NOK:'🇳🇴', NPR:'🇳🇵', NZD:'🇳🇿',
  OMR:'🇴🇲', PHP:'🇵🇭', PKR:'🇵🇰', PNR:'🇵🇰', PLN:'🇵🇱', QAR:'🇶🇦',
  RUB:'🇷🇺', SAR:'🇸🇦', SEK:'🇸🇪', SGD:'🇸🇬', THB:'🇹🇭',
  TRY:'🇹🇷', TWD:'🇹🇼', USD:'🇺🇸', VND:'🇻🇳', ZAR:'🇿🇦',
};

const DEFAULT_CURRENCIES = [
  { code: 'INR', name: 'Indian Rupee',       symbol: '₹'   },
  { code: 'USD', name: 'US Dollar',           symbol: '$'   },
  { code: 'EUR', name: 'Euro',                symbol: '€'   },
  { code: 'GBP', name: 'British Pound',       symbol: '£'   },
  { code: 'SAR', name: 'Saudi Riyal',         symbol: '﷼'   },
  { code: 'AED', name: 'UAE Dirham',          symbol: 'د.إ' },
  { code: 'SGD', name: 'Singapore Dollar',    symbol: 'S$'  },
  { code: 'AUD', name: 'Australian Dollar',   symbol: 'A$'  },
  { code: 'CAD', name: 'Canadian Dollar',     symbol: 'C$'  },
  { code: 'JPY', name: 'Japanese Yen',        symbol: '¥'   },
  { code: 'CNY', name: 'Chinese Yuan',        symbol: '¥'   },
  { code: 'MYR', name: 'Malaysian Ringgit',   symbol: 'RM'  },
  { code: 'QAR', name: 'Qatari Riyal',        symbol: '﷼'   },
  { code: 'KWD', name: 'Kuwaiti Dinar',       symbol: 'KD'  },
  { code: 'PKR', name: 'Pakistani Rupee',     symbol: '₨'   },
  { code: 'LKR', name: 'Sri Lanka Rupee',     symbol: 'Rs'  },
];

function flag(code: string) {
  return CURRENCY_FLAGS[code] ? CURRENCY_FLAGS[code] + '\u00A0' : '';
}

function fmtRate(n: number, minDec = 4, maxDec = 6) {
  return Number(n).toLocaleString(undefined, { minimumFractionDigits: minDec, maximumFractionDigits: maxDec });
}

// ─────────────────────────────────────────────────────────────────────────────
// Toast notification
// ─────────────────────────────────────────────────────────────────────────────

interface Toast { id: string; message: string; type: 'success' | 'error' | 'warning' | 'info'; }
const TOAST_ICONS: Record<string, string> = {
  success: 'fa-circle-check', error: 'fa-circle-xmark',
  warning: 'fa-triangle-exclamation', info: 'fa-circle-info',
};

function ToastContainer({ toasts, onDismiss }: { toasts: Toast[]; onDismiss: (id: string) => void }) {
  return (
    <div className="er-toast-container" role="status" aria-live="polite">
      {toasts.map(t => (
        <div key={t.id} className={`er-toast er-toast--visible er-toast--${t.type}`}>
          <i className={`fa-solid ${TOAST_ICONS[t.type]}`} />
          <span>{t.message}</span>
          <button className="er-toast-close" onClick={() => onDismiss(t.id)} title="Dismiss">
            <i className="fa-solid fa-xmark" />
          </button>
        </div>
      ))}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Currency badge
// ─────────────────────────────────────────────────────────────────────────────

function CcyBadge({ code, muted }: { code: string; muted?: boolean }) {
  return (
    <span className={`er-currency-badge${muted ? ' er-badge-muted' : ''}`}>
      {flag(code)}{code}
    </span>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Inline edit row
// ─────────────────────────────────────────────────────────────────────────────

interface InlineEditRowProps {
  rate: StoredRate;
  onSave: (id: string, newRate: number, newDate: string) => void;
  onCancel: () => void;
}
function InlineEditRow({ rate: r, onSave, onCancel }: InlineEditRowProps) {
  const [rateVal, setRateVal] = useState(String(r.rate));
  const [dateVal, setDateVal] = useState(r.effectiveDate);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => { inputRef.current?.focus(); }, []);

  const revNum = parseFloat(rateVal);
  const revStr = !isNaN(revNum) && revNum > 0
    ? fmtRate(1 / revNum)
    : '—';

  return (
    <tr className="er-editing">
      <td>
        <CcyBadge code={r.fromCode} />
        <span className="er-direction-arrow">→</span>
        <CcyBadge code={r.toCode} />
      </td>
      <td>
        <input
          ref={inputRef}
          className="er-inline-input"
          type="number"
          value={rateVal}
          min="0.000001"
          step="any"
          style={{ width: 110 }}
          onChange={e => setRateVal(e.target.value)}
        />
      </td>
      <td>
        <CcyBadge code={r.toCode} muted />
        <span className="er-direction-arrow">→</span>
        <CcyBadge code={r.fromCode} muted />
      </td>
      <td className="er-rate-val er-rate-derived">
        {revStr} <span className="er-auto-tag">auto</span>
      </td>
      <td>
        <input
          className="er-inline-input"
          type="date"
          value={dateVal}
          onChange={e => setDateVal(e.target.value)}
        />
      </td>
      <td className="er-actions">
        <button
          className="ref-btn-edit er-il-save-btn"
          title="Save"
          onClick={() => {
            const v = parseFloat(rateVal);
            if (!isNaN(v) && v > 0 && dateVal) onSave(r.id, v, dateVal);
          }}
        >
          <i className="fa-solid fa-floppy-disk" />
        </button>
        <button className="ref-btn-delete er-il-cancel-btn" title="Cancel" onClick={onCancel}>
          <i className="fa-solid fa-xmark" />
        </button>
      </td>
    </tr>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Main component
// ─────────────────────────────────────────────────────────────────────────────

const EMPTY_FORM = { fromCode: '', toCode: '', rate: '', effectiveDate: new Date().toISOString().slice(0, 10) };

export default function ExchangeRates() {
  const { rates, loading: ratesLoading, error: ratesError, refetch: refetchRates, add: addRate, update: updateRate, remove: deleteRate } = useExchangeRates();
  const { currencies, error: currenciesError, refetch: refetchCurrencies } = useCurrencies();
  const { getValues: getPicklistValues } = usePicklistValues();
  // Alias rates to StoredRate shape — the hook already joins fromCode/toCode
  const storedRates = rates as unknown as StoredRate[];
  const [form, setForm]             = useState(EMPTY_FORM);
  const [editId, setEditId]         = useState<string | null>(null);
  const [inlineEditId, setInlineEditId] = useState<string | null>(null);
  const [reverseWarning, setReverseWarning] = useState('');
  const [dateWarning, setDateWarning]   = useState('');
  const [reversePreview, setReversePreview] = useState('');
  const [toasts, setToasts]         = useState<Toast[]>([]);
  const [deleteModal, setDeleteModal] = useState<{ isOpen: boolean; rate: StoredRate | null }>({ isOpen: false, rate: null });

  // Currency options: if the admin has configured currencies in Reference Data → Currencies,
  // build the list directly from that picklist (so all user-configured currencies show up
  // regardless of whether the currencies table marks them active).
  // Fall back to the currencies table / DEFAULT_CURRENCIES only when the picklist is empty.
  const currencyOptions = useMemo(() => {
    const plCurrencies = getPicklistValues('CURRENCY');
    if (plCurrencies.length > 0) {
      return plCurrencies
        .filter(p => p.meta?.code)
        .map(p => ({ code: (p.meta as { code: string }).code, name: p.value }))
        .sort((a, b) => a.code.localeCompare(b.code));
    }
    // Fallback when no currencies configured in Reference Data
    return currencies.length > 0
      ? currencies.map(c => ({ code: c.code, name: c.name }))
      : DEFAULT_CURRENCIES.map(c => ({ code: c.code, name: c.name }));
  }, [currencies, getPicklistValues]);

  // Toast helpers
  function addToast(message: string, type: Toast['type'] = 'success', duration = 3000) {
    const id = `t_${Date.now()}`;
    setToasts(prev => [...prev, { id, message, type }]);
    setTimeout(() => setToasts(prev => prev.filter(t => t.id !== id)), duration);
  }
  function dismissToast(id: string) { setToasts(prev => prev.filter(t => t.id !== id)); }

  // Live validation when form fields change
  useEffect(() => {
    const { fromCode, toCode, rate } = form;

    // Reverse preview
    const rateNum = parseFloat(rate);
    if (fromCode && toCode && fromCode !== toCode && !isNaN(rateNum) && rateNum > 0) {
      setReversePreview(`${fmtRate(1 / rateNum)}`);
    } else {
      setReversePreview('');
    }

    // Reverse duplicate check (blocking)
    if (fromCode && toCode && fromCode !== toCode) {
      const reverseExists = storedRates.some(r =>
        r.id !== editId &&
        r.fromCode === toCode && r.toCode === fromCode
      );
      if (reverseExists) {
        setReverseWarning(
          `A rate for ${flag(toCode)}${toCode} → ${flag(fromCode)}${fromCode} already exists. ` +
          `The reverse is calculated automatically — you don't need to store both directions.`
        );
      } else {
        setReverseWarning('');
      }
    } else {
      setReverseWarning('');
    }
  }, [form, storedRates, editId]);

  // Date warning (non-blocking) — checks if adding a newer rate for same pair
  useEffect(() => {
    const { fromCode, toCode, effectiveDate } = form;
    if (!fromCode || !toCode || !effectiveDate || fromCode === toCode) { setDateWarning(''); return; }
    const peers = storedRates.filter(r =>
      r.id !== editId && r.fromCode === fromCode && r.toCode === toCode
    );
    const newer = peers.filter(r => r.effectiveDate > effectiveDate);
    if (newer.length) {
      setDateWarning(
        `A newer rate for this pair already exists (dated ${newer.sort((a, b) => b.effectiveDate.localeCompare(a.effectiveDate))[0].effectiveDate}). ` +
        `This rate will only apply to expenses before that date.`
      );
    } else {
      setDateWarning('');
    }
  }, [form, rates, editId]);

  function swapCurrencies() {
    setForm(f => ({ ...f, fromCode: f.toCode, toCode: f.fromCode }));
  }

  function resetForm() {
    setForm(EMPTY_FORM);
    setEditId(null);
    setReverseWarning('');
    setDateWarning('');
    setReversePreview('');
  }

  async function saveRate() {
    const { fromCode, toCode, rate, effectiveDate } = form;
    if (!fromCode || !toCode || !rate || !effectiveDate) {
      addToast('All fields are required.', 'error'); return;
    }
    if (fromCode === toCode) {
      addToast('From and To currencies must differ. Same-currency rates are always 1.', 'error'); return;
    }
    if (reverseWarning) {
      addToast('Cannot save: a reverse rate for this pair already exists.', 'error'); return;
    }
    const rateNum = parseFloat(rate);
    if (isNaN(rateNum) || rateNum <= 0) {
      addToast('Please enter a valid positive rate.', 'error'); return;
    }

    if (editId) {
      const err = await updateRate(editId, { rate: rateNum, effectiveDate });
      if (err) { addToast(err, 'error'); return; }
      addToast(`${flag(fromCode)}${fromCode} → ${flag(toCode)}${toCode} rate updated.`, 'success');
    } else {
      const fromCcy = currencies.find(c => c.code === fromCode);
      const toCcy   = currencies.find(c => c.code === toCode);
      if (!fromCcy || !toCcy) {
        addToast('Currency not found in database.', 'error'); return;
      }
      const err = await addRate({ fromCurrencyId: fromCcy.id, toCurrencyId: toCcy.id, rate: rateNum, effectiveDate });
      if (err) { addToast(err, 'error'); return; }
      addToast(`${flag(fromCode)}${fromCode} → ${flag(toCode)}${toCode} rate saved.`, 'success');
    }
    resetForm();
  }

  async function saveInlineEdit(id: string, newRate: number, newDate: string) {
    const r = storedRates.find(x => x.id === id);
    const err = await updateRate(id, { rate: newRate, effectiveDate: newDate });
    if (err) { addToast(err, 'error'); return; }
    setInlineEditId(null);
    if (r) addToast(`${flag(r.fromCode)}${r.fromCode} → ${flag(r.toCode)}${r.toCode} rate updated.`, 'success');
  }

  async function removeRate(id: string) {
    const r = storedRates.find(x => x.id === id);
    const err = await deleteRate(id);
    if (err) { addToast(err, 'error'); return; }
    if (r) addToast(`${flag(r.fromCode)}${r.fromCode} → ${flag(r.toCode)}${r.toCode} rate deleted.`, 'info');
  }

  function requestDelete(rate: StoredRate) {
    setDeleteModal({ isOpen: true, rate });
  }

  function confirmDelete() {
    if (deleteModal.rate) removeRate(deleteModal.rate.id);
    setDeleteModal({ isOpen: false, rate: null });
  }

  function cancelDelete() {
    setDeleteModal({ isOpen: false, rate: null });
  }

  // Sort rates descending by effectiveDate
  const sortedRates = useMemo(() =>
    [...storedRates].sort((a, b) => b.effectiveDate.localeCompare(a.effectiveDate)),
    [storedRates]
  );

  // Trend indicator per row
  function trendFor(r: StoredRate) {
    const peers = storedRates
      .filter(p => p.fromCode === r.fromCode && p.toCode === r.toCode && p.id !== r.id && p.effectiveDate < r.effectiveDate)
      .sort((a, b) => b.effectiveDate.localeCompare(a.effectiveDate));
    if (!peers.length) return null;
    const prev = peers[0].rate;
    if (r.rate > prev) return <span className="er-trend er-trend--up" title={`Higher than previous rate (${prev})`}>↑</span>;
    if (r.rate < prev) return <span className="er-trend er-trend--down" title={`Lower than previous rate (${prev})`}>↓</span>;
    return <span className="er-trend er-trend--same" title="Same as previous rate">→</span>;
  }

  const showPreview = !!(reversePreview && form.fromCode && form.toCode && form.fromCode !== form.toCode);

  if (ratesError)      return <ErrorBanner message={ratesError}     onRetry={refetchRates} />;
  if (currenciesError) return <ErrorBanner message={currenciesError} onRetry={refetchCurrencies} />;

  return (
    <div className="ar-panel" style={{ position: 'relative' }}>
      {/* Loading overlay while rates are fetching */}
      {ratesLoading && (
        <div style={{ textAlign: 'center', padding: '20px', color: '#6B7280', fontSize: 13 }}>
          <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />
          Loading rates…
        </div>
      )}
      {/* Page header */}
      <h2 className="page-title">Exchange Rates</h2>
      <p className="page-subtitle">
        Define currency conversion rates. Enter each pair in <strong>one direction only</strong> — the reverse rate is calculated automatically.
      </p>

      {/* Add / Edit form card */}
      <div className="er-form-card">
        <h3 className="er-form-title">
          <i className={`fa-solid ${editId ? 'fa-pen' : 'fa-plus'}`} />
          <span>{editId ? 'Edit Exchange Rate' : 'Add Exchange Rate'}</span>
        </h3>

        {/* Helper text */}
        <p className="er-helper-text">
          <i className="fa-solid fa-circle-info" />
          <span>
            Enter the rate in <strong>one direction only</strong> (e.g. SAR → INR = 22.50) —
            the reverse rate is calculated automatically as <strong>1 ÷ rate</strong>.
            Same-currency entries are never needed; the system always returns <strong>1</strong>.
            For effective dates, the system picks the <strong>latest rate</strong> whose date is
            on or before the expense date.
          </span>
        </p>

        {/* Form fields */}
        <div className="er-form-grid">
          {/* Currency pair + swap */}
          <div className="er-pair-group">
            <div className="form-group">
              <label htmlFor="er-from-currency">From Currency</label>
              <select
                id="er-from-currency"
                value={form.fromCode}
                onChange={e => setForm(f => ({ ...f, fromCode: e.target.value }))}
                required
              >
                <option value="">-- Select --</option>
                {currencyOptions.map(c => (
                  <option key={c.code} value={c.code}>
                    {flag(c.code)}{c.code} – {c.name}
                  </option>
                ))}
              </select>
            </div>

            <button type="button" className="er-swap-btn" title="Swap currencies" onClick={swapCurrencies}>
              <i className="fa-solid fa-right-left" />
            </button>

            <div className="form-group">
              <label htmlFor="er-to-currency">To Currency</label>
              <select
                id="er-to-currency"
                value={form.toCode}
                onChange={e => setForm(f => ({ ...f, toCode: e.target.value }))}
                required
              >
                <option value="">-- Select --</option>
                {currencyOptions.map(c => (
                  <option key={c.code} value={c.code}>
                    {flag(c.code)}{c.code} – {c.name}
                  </option>
                ))}
              </select>
            </div>
          </div>

          {/* Rate */}
          <div className="form-group">
            <label htmlFor="er-rate">Exchange Rate</label>
            <input
              id="er-rate"
              type="number"
              placeholder="e.g. 83.50"
              min="0.000001"
              step="any"
              value={form.rate}
              onChange={e => setForm(f => ({ ...f, rate: e.target.value }))}
              required
            />
          </div>

          {/* Effective date */}
          <div className="form-group">
            <label htmlFor="er-effective-date">
              Effective Date{' '}
              <span
                className="er-date-tip"
                title="The system picks the latest rate whose effective date is on or before the expense date. Example: rates on Jan 1 and Mar 1 — an expense dated Feb 15 uses the Jan 1 rate."
              >
                <i className="fa-solid fa-circle-question" />
              </span>
            </label>
            <input
              id="er-effective-date"
              type="date"
              value={form.effectiveDate}
              onChange={e => setForm(f => ({ ...f, effectiveDate: e.target.value }))}
              required
            />
          </div>
        </div>

        {/* Live reverse rate preview */}
        {showPreview && (
          <div className="er-reverse-preview">
            <i className="fa-solid fa-rotate" />
            {' '}Reverse rate (auto):
            <span className="er-preview-pair">
              <CcyBadge code={form.toCode} muted />
              <span className="er-direction-arrow">→</span>
              <CcyBadge code={form.fromCode} muted />
            </span>
            = <strong>{reversePreview}</strong>
          </div>
        )}

        {/* Reverse duplicate warning (blocking) */}
        {reverseWarning && (
          <div className="er-inline-warning er-inline-warning--block">
            <i className="fa-solid fa-ban" />
            <span>{reverseWarning}</span>
          </div>
        )}

        {/* Date info warning (non-blocking) */}
        {dateWarning && (
          <div className="er-inline-warning er-inline-warning--info">
            <i className="fa-solid fa-circle-exclamation" />
            <span>{dateWarning}</span>
          </div>
        )}

        {/* Actions */}
        <div className="er-form-actions">
          <button type="button" className="btn-add" id="er-submit-btn" onClick={saveRate}>
            <i className="fa-solid fa-floppy-disk" /> Save Rate
          </button>
          {editId && (
            <button type="button" className="btn-cancel" id="er-cancel-btn" onClick={resetForm}>
              Cancel
            </button>
          )}
        </div>
      </div>

      {/* Rates table */}
      <div className="er-table-wrap" style={{ overflow: 'hidden', maxWidth: '100%' }}>
        <div style={{ overflowY: 'auto', maxHeight: 'calc(100vh - 380px)' }}>
        <table className="er-table" id="exrate-table">
          <thead style={{ position: 'sticky', top: 0, zIndex: 5 }}>
            <tr>
              <th>Stored Direction</th>
              <th>Rate</th>
              <th>Reverse Direction</th>
              <th>Reverse Rate</th>
              <th>Effective Date</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody id="exrate-tbody">
            {sortedRates.length === 0 ? (
              <tr>
                <td colSpan={6} className="er-empty-state">
                  <div className="er-empty-icon">
                    <i className="fa-solid fa-arrow-right-arrow-left" />
                  </div>
                  <p className="er-empty-msg">
                    No exchange rates defined yet.<br />
                    Add your first rate to enable multi-currency expenses.
                  </p>
                  <button
                    className="btn-add er-empty-cta"
                    onClick={() => {
                      document.querySelector('.er-form-card')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
                      setTimeout(() => (document.getElementById('er-from-currency') as HTMLSelectElement)?.focus(), 300);
                    }}
                  >
                    <i className="fa-solid fa-plus" /> Add First Rate
                  </button>
                </td>
              </tr>
            ) : sortedRates.map(r => {
              if (inlineEditId === r.id) {
                return (
                  <InlineEditRow
                    key={r.id}
                    rate={r}
                    onSave={saveInlineEdit}
                    onCancel={() => setInlineEditId(null)}
                  />
                );
              }
              const trend = trendFor(r);
              const rev = 1 / r.rate;
              return (
                <tr key={r.id} data-id={r.id}>
                  {/* Stored direction */}
                  <td>
                    <CcyBadge code={r.fromCode} />
                    <span className="er-direction-arrow">→</span>
                    <CcyBadge code={r.toCode} />
                  </td>
                  {/* Rate */}
                  <td className="er-rate-val er-rate-display" data-raw={r.rate}>
                    {fmtRate(r.rate)}{trend && <>{' '}{trend}</>}
                  </td>
                  {/* Reverse direction */}
                  <td>
                    <CcyBadge code={r.toCode} muted />
                    <span className="er-direction-arrow">→</span>
                    <CcyBadge code={r.fromCode} muted />
                  </td>
                  {/* Reverse rate */}
                  <td className="er-rate-val er-rate-derived er-rev-display" title={`Auto-calculated: 1 ÷ ${fmtRate(r.rate)}`}>
                    <em>{fmtRate(rev)}</em>{' '}
                    <span className="er-auto-tag">AUTO</span>
                  </td>
                  {/* Effective date */}
                  <td className="er-date-display">{r.effectiveDate}</td>
                  {/* Actions */}
                  <td className="er-actions">
                    <button
                      className="ref-btn-edit er-inline-edit-btn"
                      title="Edit inline"
                      onClick={() => { setInlineEditId(r.id); setEditId(null); }}
                    >
                      <i className="fa-solid fa-pen-to-square" />
                    </button>
                    <button
                      className="ref-btn-delete er-delete-btn"
                      title="Delete"
                      onClick={() => requestDelete(r)}
                    >
                      <i className="fa-solid fa-trash" />
                    </button>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
        </div>
      </div>

      {/* Toast container */}
      <ToastContainer toasts={toasts} onDismiss={dismissToast} />

      {/* ── Delete confirmation modal ──────────────────────────────────────── */}
      <ConfirmationModal
        isOpen={deleteModal.isOpen}
        title="Delete Exchange Rate"
        message={
          deleteModal.rate
            ? `Are you sure you want to delete the ${deleteModal.rate.fromCode} → ${deleteModal.rate.toCode} exchange rate?`
            : ''
        }
        warning="This action cannot be undone and will permanently remove the exchange rate."
        confirmText="Delete"
        cancelText="Cancel"
        destructive={true}
        onConfirm={confirmDelete}
        onCancel={cancelDelete}
      />
    </div>
  );
}
