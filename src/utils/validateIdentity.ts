/**
 * validateIdentity — country + ID-type aware identity number validation.
 *
 * Call with the resolved country name (e.g. "India") and the resolved
 * ID type label (e.g. "Aadhaar") — not UUIDs.
 *
 * Each rule returns:
 *   error       — string | null   (null = valid)
 *   hint        — user-facing format guide shown below the input
 *   placeholder — input placeholder text
 *   validity    — { years: number } | { lifetime: true }
 *                 Used to auto-default the Expiry Date field.
 *                 lifetime → sets expiry to 9999-12-31 and shows a note.
 */

export type IdValidity =
  | { years: number; label: string }
  | { lifetime: true;  label: string };

export interface IdRule {
  hint: string;
  placeholder: string;
  validity: IdValidity;
  validate: (raw: string) => string | null;
}

// ─── normalise helpers ────────────────────────────────────────────────────────
const strip = (s: string, ...chars: string[]) =>
  chars.reduce((acc, c) => acc.split(c).join(''), s);

// ─── rules ───────────────────────────────────────────────────────────────────
const RULES: Record<string, Record<string, IdRule>> = {

  // ── India ─────────────────────────────────────────────────────────────────
  india: {
    aadhaar: {
      hint:        '12-digit number — spaces and hyphens are ignored (e.g. 1234 5678 9012)',
      placeholder: 'e.g. 1234 5678 9012',
      validity:    { lifetime: true, label: 'Lifetime — does not expire' },
      validate(raw) {
        const n = strip(raw, ' ', '-');
        if (!/^\d{12}$/.test(n)) return 'Enter a valid 12-digit Aadhaar number (spaces and hyphens are ignored).';
        return null;
      },
    },
    pan: {
      hint:        '10 characters — 5 letters, 4 digits, 1 letter (e.g. ABCDE1234F)',
      placeholder: 'e.g. ABCDE1234F',
      validity:    { lifetime: true, label: 'Lifetime — does not expire' },
      validate(raw) {
        const n = raw.trim().toUpperCase();
        if (!/^[A-Z]{5}[0-9]{4}[A-Z]{1}$/.test(n)) return 'Enter a valid PAN (e.g. ABCDE1234F).';
        return null;
      },
    },
    'driving license': {
      hint:        'State code + RTO + year + 7 digits, spaces/hyphens ignored (e.g. TN0120121234567)',
      placeholder: 'e.g. TN0120121234567',
      validity:    { years: 20, label: 'Valid for 20 years' },
      validate(raw) {
        const n = strip(raw, ' ', '-').toUpperCase();
        if (!/^[A-Z]{2}[0-9]{2}[0-9]{4}[0-9]{7}$/.test(n)) return 'Enter a valid Driving License number (e.g. TN0120121234567).';
        return null;
      },
    },
  },

  // ── Pakistan ──────────────────────────────────────────────────────────────
  pakistan: {
    cnic: {
      hint:        '13 digits in format 12345-1234567-1 (hyphens are optional)',
      placeholder: 'e.g. 12345-1234567-1',
      validity:    { years: 10, label: 'Valid for 10 years' },
      validate(raw) {
        const n = strip(raw, '-', ' ');
        if (!/^\d{13}$/.test(n)) return 'Enter a valid CNIC — 13 digits (e.g. 12345-1234567-1).';
        return null;
      },
    },
    nicop: {
      hint:        '13 digits in format 12345-1234567-1 (hyphens are optional)',
      placeholder: 'e.g. 12345-1234567-1',
      validity:    { years: 10, label: 'Valid for 10 years' },
      validate(raw) {
        const n = strip(raw, '-', ' ');
        if (!/^\d{13}$/.test(n)) return 'Enter a valid NICOP — 13 digits (e.g. 12345-1234567-1).';
        return null;
      },
    },
  },

  // ── Saudi Arabia ──────────────────────────────────────────────────────────
  'saudi arabia': {
    iqama: {
      hint:        '10 digits starting with 2 (e.g. 2123456789)',
      placeholder: 'e.g. 2123456789',
      validity:    { years: 1, label: 'Valid for 1 year (renewable annually)' },
      validate(raw) {
        const n = strip(raw, ' ', '-');
        if (!/^2[0-9]{9}$/.test(n)) return 'Iqama must be 10 digits starting with 2 (e.g. 2123456789).';
        return null;
      },
    },
    'saudi national id': {
      hint:        '10 digits starting with 1 (e.g. 1123456789)',
      placeholder: 'e.g. 1123456789',
      validity:    { years: 10, label: 'Valid for 10 years' },
      validate(raw) {
        const n = strip(raw, ' ', '-');
        if (!/^1[0-9]{9}$/.test(n)) return 'National ID must be 10 digits starting with 1 (e.g. 1123456789).';
        return null;
      },
    },
  },

  // ── Sri Lanka ─────────────────────────────────────────────────────────────
  'sri lanka': {
    nic: {
      hint:        'Old format: 9 digits + V or X (e.g. 123456789V) · New format: 12 digits (e.g. 199012345678)',
      placeholder: 'e.g. 123456789V or 199012345678',
      validity:    { lifetime: true, label: 'Lifetime — does not expire' },
      validate(raw) {
        const n = strip(raw, ' ', '-').toUpperCase();
        if (!/^[0-9]{9}[VX]$/.test(n) && !/^[0-9]{12}$/.test(n))
          return 'Enter a valid NIC — old format: 9 digits + V/X (e.g. 123456789V), or new format: 12 digits (e.g. 199012345678).';
        return null;
      },
    },
  },
};

/**
 * Look up the rule for a given country + ID type combination.
 * Both args are resolved display-name strings (case-insensitive).
 */
export function getIdRule(countryName: string, idTypeName: string): IdRule | null {
  const countryRules = RULES[countryName.trim().toLowerCase()];
  if (!countryRules) return null;
  return countryRules[idTypeName.trim().toLowerCase()] ?? null;
}

/**
 * Validate an identity number.
 * Returns an error string, or null if valid / no rule exists for this combination.
 */
export function validateIdentityNumber(
  countryName: string,
  idTypeName: string,
  value: string,
): string | null {
  const rule = getIdRule(countryName, idTypeName);
  if (!rule) return null;
  const trimmed = value.trim();
  if (!trimmed) return null; // presence is checked separately
  return rule.validate(trimmed);
}

/**
 * Returns the placeholder text for the ID Number input.
 */
export function idNumberPlaceholder(countryName: string, idTypeName: string): string {
  return getIdRule(countryName, idTypeName)?.placeholder ?? 'Enter ID number';
}

/**
 * Returns the format hint shown below the input (null = no hint for this type).
 */
export function idNumberHint(countryName: string, idTypeName: string): string | null {
  return getIdRule(countryName, idTypeName)?.hint ?? null;
}

/**
 * Returns a default expiry date (YYYY-MM-DD) based on validity period.
 *   - Lifetime types → '9999-12-31'
 *   - Year-based     → today + N years
 *   - Unknown type   → null (no default)
 */
export function defaultExpiryDate(countryName: string, idTypeName: string): string | null {
  const rule = getIdRule(countryName, idTypeName);
  if (!rule) return null;

  if ('lifetime' in rule.validity) return '9999-12-31';

  const d = new Date();
  d.setFullYear(d.getFullYear() + rule.validity.years);
  return d.toISOString().slice(0, 10);
}

/**
 * Returns a short validity label for display next to the Expiry Date field
 * (e.g. "Valid for 10 years", "Lifetime — does not expire").
 * Returns null if no rule exists for this type.
 */
export function idValidityLabel(countryName: string, idTypeName: string): string | null {
  return getIdRule(countryName, idTypeName)?.validity.label ?? null;
}
