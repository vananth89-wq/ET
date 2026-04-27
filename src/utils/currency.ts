import type { ExchangeRate } from '../types';

export function getCurrencySymbol(code: string): string {
  const map: Record<string, string> = {
    INR: '₹', USD: '$', EUR: '€', GBP: '£',
    AED: 'د.إ', SAR: '﷼', PKR: '₨', LKR: '₨',
    SGD: 'S$', MYR: 'RM', QAR: '﷼', KWD: 'د.ك',
    BHD: '.د.ب', OMR: '﷼', JPY: '¥', CNY: '¥',
  };
  return map[code] ?? code;
}

export function fmtAmount(amount: number, currencyCode: string): string {
  const sym = getCurrencySymbol(currencyCode);
  return `${sym}${amount.toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

export function lookupRate(
  exchangeRates: ExchangeRate[],
  fromCode: string,
  toCode: string,
  dateStr: string
): number | null {
  if (fromCode === toCode) return 1;
  const onOrBefore = exchangeRates
    .filter(r => r.fromCode === fromCode && r.toCode === toCode && r.effectiveDate <= dateStr)
    .sort((a, b) => b.effectiveDate.localeCompare(a.effectiveDate));
  return onOrBefore[0]?.rate ?? null;
}
