import { createClient } from '@supabase/supabase-js';
import type { Database } from '../types/database';

const supabaseUrl  = import.meta.env.VITE_SUPABASE_URL  as string;
const supabaseKey  = import.meta.env.VITE_SUPABASE_ANON_KEY as string;

if (!supabaseUrl || !supabaseKey) {
  throw new Error(
    'Missing Supabase environment variables.\n' +
    'Copy .env.example → .env.local and fill in your project URL and anon key.'
  );
}

export const supabase = createClient<Database>(supabaseUrl, supabaseKey, {
  auth: {
    // Persist session in localStorage across page refreshes
    persistSession: true,
    // Automatically refresh the JWT before it expires
    autoRefreshToken: true,
    // Detect session from URL after OAuth / magic-link redirect
    detectSessionInUrl: true,
    // No flowType: 'pkce' — pkce_ tokens require a code_verifier in localStorage
    // which verifyOtp() cannot use. Instead, email templates are configured to
    // send token_hash directly to the app URL, bypassing Supabase's verify
    // endpoint so email scanners cannot consume the token.
  },
});
