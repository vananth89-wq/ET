import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../lib/supabase';

export interface ExchangeRate {
  id:             string;
  fromCurrencyId: string;
  toCurrencyId:   string;
  rate:           number;
  effectiveDate:  string;
  // Joined fields
  fromCode?:      string;
  toCode?:        string;
}

interface UseExchangeRatesResult {
  rates:   ExchangeRate[];
  loading: boolean;
  error:   string | null;
  refetch: () => void;
  add:     (payload: { fromCurrencyId: string; toCurrencyId: string; rate: number; effectiveDate: string }) => Promise<string | null>;
  update:  (id: string, payload: { rate?: number; effectiveDate?: string }) => Promise<string | null>;
  remove:  (id: string) => Promise<string | null>;
}

export function useExchangeRates(): UseExchangeRatesResult {
  const [rates,   setRates]   = useState<ExchangeRate[]>([]);
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState<string | null>(null);
  const [tick,    setTick]    = useState(0);

  const refetch = useCallback(() => setTick(t => t + 1), []);

  useEffect(() => {
    let mounted = true;
    setLoading(true);
    setError(null);

    async function load() {
      try {
        const { data, error: err } = await supabase
          .from('exchange_rates')
          .select(`
            id,
            from_currency_id,
            to_currency_id,
            rate,
            effective_date,
            from_currency:currencies!exchange_rates_from_currency_id_fkey ( code ),
            to_currency:currencies!exchange_rates_to_currency_id_fkey   ( code )
          `)
          .order('effective_date', { ascending: false });

        if (err) throw err;

        if (mounted) {
          setRates(
            (data ?? []).map((row) => ({
              id:             row.id,
              fromCurrencyId: row.from_currency_id,
              toCurrencyId:   row.to_currency_id,
              rate:           Number(row.rate),
              effectiveDate:  row.effective_date,
              fromCode:       (row.from_currency as { code: string } | null)?.code ?? '',
              toCode:         (row.to_currency   as { code: string } | null)?.code ?? '',
            }))
          );
        }
      } catch (err: unknown) {
        if (mounted) {
          const msg = err instanceof Error ? err.message : String(err);
          setError(msg);
          setRates([]);
        }
      } finally {
        if (mounted) setLoading(false);
      }
    }

    load();
    return () => { mounted = false; };
  }, [tick]);

  async function add(payload: { fromCurrencyId: string; toCurrencyId: string; rate: number; effectiveDate: string }): Promise<string | null> {
    const { error: err } = await supabase.from('exchange_rates').insert({
      from_currency_id: payload.fromCurrencyId,
      to_currency_id:   payload.toCurrencyId,
      rate:             payload.rate,
      effective_date:   payload.effectiveDate,
    });
    if (err) return err.message;
    refetch();
    return null;
  }

  async function update(id: string, payload: { rate?: number; effectiveDate?: string }): Promise<string | null> {
    const patch: Record<string, unknown> = {};
    if (payload.rate          !== undefined) patch.rate           = payload.rate;
    if (payload.effectiveDate !== undefined) patch.effective_date = payload.effectiveDate;
    const { error: err } = await supabase.from('exchange_rates').update(patch).eq('id', id);
    if (err) return err.message;
    refetch();
    return null;
  }

  async function remove(id: string): Promise<string | null> {
    const { error: err } = await supabase.from('exchange_rates').delete().eq('id', id);
    if (err) return err.message;
    refetch();
    return null;
  }

  return { rates, loading, error, refetch, add, update, remove };
}
