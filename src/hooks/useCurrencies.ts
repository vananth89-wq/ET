import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../lib/supabase';
import type { Database } from '../types/database';

type CurrencyRow = Database['public']['Tables']['currencies']['Row'];

export interface Currency {
  id:     string;
  code:   string;
  name:   string;
  symbol: string;
  active: boolean;
}

function mapCurrency(row: CurrencyRow): Currency {
  return {
    id:     row.id,
    code:   row.code,
    name:   row.name,
    symbol: row.symbol,
    active: row.active,
  };
}

interface UseCurrenciesResult {
  currencies: Currency[];
  loading:    boolean;
  error:      string | null;
  refetch:    () => void;
}

export function useCurrencies(activeOnly = true): UseCurrenciesResult {
  const [currencies, setCurrencies] = useState<Currency[]>([]);
  const [loading,    setLoading]    = useState(true);
  const [error,      setError]      = useState<string | null>(null);
  const [tick,       setTick]       = useState(0);

  const refetch = useCallback(() => setTick(t => t + 1), []);

  useEffect(() => {
    let mounted = true;
    setLoading(true);
    setError(null);

    async function load() {
      try {
        let query = supabase
          .from('currencies')
          .select('*')
          .order('name', { ascending: true });

        if (activeOnly) {
          query = query.eq('active', true);
        }

        const { data, error: err } = await query;
        if (err) throw err;
        if (mounted) setCurrencies((data ?? []).map(mapCurrency));
      } catch (err: unknown) {
        if (mounted) {
          const msg = err instanceof Error ? err.message : String(err);
          setError(msg);
          setCurrencies([]);
        }
      } finally {
        if (mounted) setLoading(false);
      }
    }

    load();
    return () => { mounted = false; };
  }, [activeOnly, tick]);

  return { currencies, loading, error, refetch };
}


// ─── Lookup hook (transactional dropdowns) ────────────────────────────────────
// Queries vw_currencies_lookup — requires currencies.lookup permission (ESS has it).
// Returns active currencies only. No `active` field — view pre-filters centrally.
// Use this for currency dropdowns in expense forms, not useCurrencies().

export interface CurrencyLookup {
  id:     string;   // UUID — store this as FK, not the code string
  code:   string;   // ISO code e.g. USD, INR, SAR
  name:   string;   // US Dollar, Indian Rupee
  symbol: string;   // $, ₹, ﷼
}

interface UseCurrenciesLookupResult {
  currencies: CurrencyLookup[];
  loading:    boolean;
  error:      string | null;
}

export function useCurrenciesLookup(): UseCurrenciesLookupResult {
  const [currencies, setCurrencies] = useState<CurrencyLookup[]>([]);
  const [loading,    setLoading]    = useState(true);
  const [error,      setError]      = useState<string | null>(null);

  useEffect(() => {
    let mounted = true;
    setLoading(true);
    setError(null);

    supabase
      .from('vw_currencies_lookup')
      .select('id, code, name, symbol')
      .order('name', { ascending: true })
      .then(({ data, error: err }) => {
        if (!mounted) return;
        if (err) {
          setError(err.message);
          setCurrencies([]);
        } else {
          setCurrencies(
            (data ?? []).map(row => ({
              id:     row.id,
              code:   row.code,
              name:   row.name,
              symbol: row.symbol,
            }))
          );
        }
        setLoading(false);
      });

    return () => { mounted = false; };
  }, []);

  return { currencies, loading, error };
}
