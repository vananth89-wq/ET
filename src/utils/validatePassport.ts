/**
 * validatePassport — country-aware passport number and validity validation.
 *
 * Accepts the resolved country name (e.g. "India", "Pakistan") — not the UUID.
 * Call idCountries.find(c => String(c.id) === passportCountry)?.value to resolve.
 *
 * Passport number rules:
 *   India        [A-Z]{1}[0-9]{7}            e.g. V6543578
 *   Pakistan     [A-Z]{2}[0-9]{7}            e.g. AB1234567
 *   Saudi Arabia [0-9]{10}                   e.g. 1234567890
 *   Sri Lanka    [A-Z]{1,2}[0-9]{7}          e.g. N1234567 or AB1234567
 *   Others       Any non-empty string         (basic presence check only)
 *
 * Validity rules (all countries below: max 10 years from issue date):
 *   India, Pakistan, Saudi Arabia, Sri Lanka → expiry ≤ issue + 10 years
 */

const COUNTRY_NAME_RULES: Record<string, {
  numberPattern:   RegExp;
  numberMessage:   string;
  numberHint:      string;   // placeholder text
  numberFormatHint: string;  // descriptive hint shown below the input
  maxYears:        number | null;
  validityMessage: string;
}> = {
  'india': {
    numberPattern:    /^[A-Z]{1}[0-9]{7}$/i,
    numberMessage:    'For India, Passport Number must contain 1 letter followed by 7 digits (e.g. V6543578).',
    numberHint:       'e.g. V6543578',
    numberFormatHint: '1 letter followed by 7 digits (e.g. V6543578)',
    maxYears:         10,
    validityMessage:  'For India, passport validity cannot exceed 10 years from the Issue Date.',
  },
  'pakistan': {
    numberPattern:    /^[A-Z]{2}[0-9]{7}$/i,
    numberMessage:    'For Pakistan, Passport Number must contain 2 letters followed by 7 digits (e.g. AB1234567).',
    numberHint:       'e.g. AB1234567',
    numberFormatHint: '2 letters followed by 7 digits (e.g. AB1234567)',
    maxYears:         10,
    validityMessage:  'For Pakistan, passport validity cannot exceed 10 years from the Issue Date.',
  },
  'saudi arabia': {
    numberPattern:    /^[0-9]{10}$/,
    numberMessage:    'For Saudi Arabia, Passport Number must contain 10 digits (e.g. 1234567890).',
    numberHint:       'e.g. 1234567890',
    numberFormatHint: '10 numeric digits (e.g. 1234567890)',
    maxYears:         10,
    validityMessage:  'For Saudi Arabia, passport validity cannot exceed 10 years from the Issue Date.',
  },
  'sri lanka': {
    numberPattern:    /^[A-Z]{1,2}[0-9]{7}$/i,
    numberMessage:    'Please enter a valid Sri Lankan Passport Number (e.g. N1234567 or AB1234567).',
    numberHint:       'e.g. N1234567',
    numberFormatHint: '1–2 letters followed by 7 digits (e.g. N1234567 or AB1234567)',
    maxYears:         10,
    validityMessage:  'For Sri Lanka, passport validity cannot exceed 10 years from the Issue Date.',
  },
};

/**
 * Validate passport number for the given country.
 * @param countryName  Resolved display name from picklist (e.g. "India")
 * @param number       Raw passport number string entered by user
 * @returns error message or null
 */
export function validatePassportNumber(countryName: string, number: string): string | null {
  const n = number.trim().toUpperCase();
  if (!n) return 'Passport Number is required.';

  const rule = COUNTRY_NAME_RULES[countryName.trim().toLowerCase()];
  if (!rule) return null; // no specific rule for this country

  return rule.numberPattern.test(n) ? null : rule.numberMessage;
}

/**
 * Validate passport expiry against issue date for the given country.
 * @param countryName  Resolved display name from picklist
 * @param issueDate    ISO date string YYYY-MM-DD
 * @param expiryDate   ISO date string YYYY-MM-DD
 * @returns error message or null
 */
export function validatePassportValidity(
  countryName: string,
  issueDate: string,
  expiryDate: string,
): string | null {
  if (!issueDate || !expiryDate) return null; // presence validated elsewhere

  const rule = COUNTRY_NAME_RULES[countryName.trim().toLowerCase()];
  if (!rule || rule.maxYears === null) return null;

  const issue  = new Date(issueDate);
  const expiry = new Date(expiryDate);

  if (isNaN(issue.getTime()) || isNaN(expiry.getTime())) return null;

  if (expiry <= issue) return 'Expiry Date must be after Issue Date.';

  // Max validity check
  const maxExpiry = new Date(issue);
  maxExpiry.setFullYear(maxExpiry.getFullYear() + rule.maxYears);

  return expiry > maxExpiry ? rule.validityMessage : null;
}

/**
 * Returns a sample placeholder for the passport number input.
 */
export function passportNumberPlaceholder(countryName: string): string {
  const rule = COUNTRY_NAME_RULES[countryName.trim().toLowerCase()];
  return rule?.numberHint ?? 'e.g. AB1234567';
}

/**
 * Returns a descriptive format hint shown below the passport number input.
 * Returns null for countries with no specific rule.
 */
export function passportNumberHint(countryName: string): string | null {
  const rule = COUNTRY_NAME_RULES[countryName.trim().toLowerCase()];
  return rule?.numberFormatHint ?? null;
}

/**
 * Returns a validity hint for the passport expiry field (e.g. "Valid for up to 10 years").
 * Returns null for countries with no specific rule.
 */
export function passportValidityHint(countryName: string): string | null {
  const rule = COUNTRY_NAME_RULES[countryName.trim().toLowerCase()];
  if (!rule || rule.maxYears === null) return null;
  return `Valid for up to ${rule.maxYears} years from the Issue Date`;
}
