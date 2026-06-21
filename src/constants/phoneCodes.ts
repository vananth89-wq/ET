/**
 * PHONE_CODES — shared list of dial prefixes used across the app.
 *
 * Used by:
 *   - AddEmployee.tsx   (new hire form, contact section)
 *   - WorkflowReview.tsx (inline edit for hire review, phone_code field type)
 */
export const PHONE_CODES: { code: string; flag: string; label: string }[] = [
  { code: '+1',   flag: '🇺🇸', label: '+1'   },
  { code: '+7',   flag: '🇷🇺', label: '+7'   },
  { code: '+27',  flag: '🇿🇦', label: '+27'  },
  { code: '+33',  flag: '🇫🇷', label: '+33'  },
  { code: '+34',  flag: '🇪🇸', label: '+34'  },
  { code: '+39',  flag: '🇮🇹', label: '+39'  },
  { code: '+44',  flag: '🇬🇧', label: '+44'  },
  { code: '+49',  flag: '🇩🇪', label: '+49'  },
  { code: '+52',  flag: '🇲🇽', label: '+52'  },
  { code: '+55',  flag: '🇧🇷', label: '+55'  },
  { code: '+60',  flag: '🇲🇾', label: '+60'  },
  { code: '+61',  flag: '🇦🇺', label: '+61'  },
  { code: '+62',  flag: '🇮🇩', label: '+62'  },
  { code: '+63',  flag: '🇵🇭', label: '+63'  },
  { code: '+64',  flag: '🇳🇿', label: '+64'  },
  { code: '+65',  flag: '🇸🇬', label: '+65'  },
  { code: '+66',  flag: '🇹🇭', label: '+66'  },
  { code: '+81',  flag: '🇯🇵', label: '+81'  },
  { code: '+82',  flag: '🇰🇷', label: '+82'  },
  { code: '+84',  flag: '🇻🇳', label: '+84'  },
  { code: '+86',  flag: '🇨🇳', label: '+86'  },
  { code: '+91',  flag: '🇮🇳', label: '+91'  },
  { code: '+92',  flag: '🇵🇰', label: '+92'  },
  { code: '+94',  flag: '🇱🇰', label: '+94'  },
  { code: '+880', flag: '🇧🇩', label: '+880' },
  { code: '+966', flag: '🇸🇦', label: '+966' },
  { code: '+971', flag: '🇦🇪', label: '+971' },
  { code: '+977', flag: '🇳🇵', label: '+977' },
];

/** Returns the flag emoji for a dial code, e.g. '+91' → '🇮🇳'. Falls back to '🌐'.
 *  Handles both '+91' and '91' formats. */
export function phoneFlag(countryCode?: string | null): string {
  if (!countryCode) return '🌐';
  const normalized = countryCode.startsWith('+') ? countryCode : `+${countryCode}`;
  return PHONE_CODES.find(p => p.code === normalized)?.flag ?? '🌐';
}
