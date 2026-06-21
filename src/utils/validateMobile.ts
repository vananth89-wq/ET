/**
 * validateMobile — country-aware mobile number validation.
 *
 * Takes the dial code (e.g. "+91") and the raw mobile string the user typed.
 * Returns an error message string, or null if valid.
 *
 * Rules (numbers entered WITHOUT the country prefix):
 *   +91  India        10 digits starting with 6–9
 *   +92  Pakistan     11 digits in format 03XXXXXXXXX
 *   +966 Saudi Arabia 10 digits in format 05XXXXXXXX
 *   +94  Sri Lanka    10 digits in format 07XXXXXXXX
 *   +20  Egypt        11 digits in format 01XXXXXXXXX
 *   +44  UK           10 digits starting with 7, OR 11 digits starting with 07
 *   +971 UAE          9 digits starting with 5, OR 10 digits starting with 05
 *
 * All other country codes: 7–15 digits (generic ITU range).
 */

const RULES: Record<string, { pattern: RegExp; message: string; placeholder: string; hint: string }> = {
  '+91': {
    pattern:     /^[6-9]\d{9}$/,
    placeholder: 'e.g. 9876543210',
    message:     'Please enter a valid Indian mobile number (10 digits starting with 6–9).',
    hint:        '10 digits, starting with 6, 7, 8, or 9',
  },
  '+92': {
    pattern:     /^03\d{9}$/,
    placeholder: 'e.g. 03001234567',
    message:     'Please enter a valid Pakistan mobile number (e.g., 03001234567).',
    hint:        '11 digits starting with 03 (e.g. 03001234567)',
  },
  '+966': {
    pattern:     /^05\d{8}$/,
    placeholder: 'e.g. 0501234567',
    message:     'Please enter a valid Saudi Arabia mobile number (e.g., 0501234567).',
    hint:        '10 digits starting with 05 (e.g. 0501234567)',
  },
  '+94': {
    pattern:     /^07\d{8}$/,
    placeholder: 'e.g. 0712345678',
    message:     'Please enter a valid Sri Lankan mobile number (e.g., 0712345678).',
    hint:        '10 digits starting with 07 (e.g. 0712345678)',
  },
  '+20': {
    pattern:     /^01\d{9}$/,
    placeholder: 'e.g. 01012345678',
    message:     'Please enter a valid Egyptian mobile number (e.g., 01012345678).',
    hint:        '11 digits starting with 01 (e.g. 01012345678)',
  },
  '+44': {
    pattern:     /^(07\d{9}|7\d{9})$/,
    placeholder: 'e.g. 07911123456',
    message:     'Please enter a valid UK mobile number (e.g., 07911123456).',
    hint:        '10–11 digits starting with 7 or 07 (e.g. 07911123456)',
  },
  '+971': {
    pattern:     /^(05\d{8}|5\d{8})$/,
    placeholder: 'e.g. 0501234567',
    message:     'Please enter a valid UAE mobile number (e.g., 0501234567).',
    hint:        '9–10 digits starting with 5 or 05 (e.g. 0501234567)',
  },
};

const GENERIC_PATTERN = /^\d{7,15}$/;

export function validateMobile(dialCode: string, mobile: string): string | null {
  const m = mobile.trim();
  if (!m) return 'Mobile number is required.';

  const rule = RULES[dialCode];
  if (rule) {
    return rule.pattern.test(m) ? null : rule.message;
  }

  // Generic fallback for all other country codes
  return GENERIC_PATTERN.test(m) ? null : 'Enter a valid mobile number (7–15 digits).';
}

/** Returns a sample placeholder for the mobile input based on the dial code. */
export function mobilePlaceholder(dialCode: string): string {
  return RULES[dialCode]?.placeholder ?? 'e.g. 9876543210';
}

/**
 * Returns a descriptive format hint shown below the mobile input.
 * Returns null for dial codes with no specific rule (generic fallback).
 */
export function mobileHint(dialCode: string): string | null {
  return RULES[dialCode]?.hint ?? null;
}
