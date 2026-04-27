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
    // Detect session from URL hash after OAuth redirect
    detectSessionInUrl: true,
  },
});
