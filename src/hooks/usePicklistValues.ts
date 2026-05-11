import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../lib/supabase';

// ─── Frontend shape (matches what existing components expect) ─────────────────
export interface PicklistValue {
  id:            string;
  picklistId:    string;   // string code e.g. 'DESIGNATION', 'CURRENCY'
  value:         string;
  parentValueId: string | null;
  refId:         string | null;
  active:        boolean;
  meta:          Record<string, string> | null;
}

// ─── Hook ─────────────────────────────────────────────────────────────────────
interface UsePicklistValuesResult {
  picklistValues: PicklistValue[];
  loading:        boolean;
  error:          string | null;
  refetch:        () => void;
  /** Convenience: get values for a specific picklist code */
  getValues:      (picklistCode: string) => PicklistValue[];
}

export function usePicklistValues(activeOnly = true): UsePicklistValuesResult {
  const [picklistValues, setPicklistValues] = useState<PicklistValue[]>([]);
  const [loading,        setLoading]        = useState(true);
  const [error,          setError]          = useState<string | null>(null);
  const [tick,           setTick]           = useState(0);

  const refetch = useCallback(() => setTick(t => t + 1), []);

  useEffect(() => {
    let mounted = true;
    setLoading(true);
    setError(null);

    async function load() {
      try {
        // Join picklist_values with picklists to get the string picklist_id code
        let query = supabase
          .from('picklist_values')
          .select(`
            id,
            value,
            parent_value_id,
            ref_id,
            active,
            meta,
            picklists ( picklist_id )
          `)
          .order('value', { ascending: true });

        if (activeOnly) {
          query = query.eq('active', true);
        }

        const { data, error: err } = await query;
        if (err) throw err;

        if (mounted) {
          setPicklistValues(
            (data ?? []).map((row) => ({
              id:            row.id,
              picklistId:    (row.picklists as { picklist_id: string } | null)?.picklist_id ?? '',
              value:         row.value,
              parentValueId: row.parent_value_id,
              refId:         row.ref_id,
              active:        row.active,
              meta:          (row.meta as Record<string, string> | null) ?? null,
            }))
          );
        }
      } catch (err: unknown) {
        if (mounted) {
          const msg = err instanceof Error ? err.message : String(err);
          setError(msg);
          setPicklistValues([]);
        }
      } finally {
        if (mounted) setLoading(false);
      }
    }

    load();
    return () => { mounted = false; };
  }, [activeOnly, tick]);

  const getValues = useCallback(
    (picklistCode: string) =>
      picklistValues.filter(v => v.picklistId === picklistCode),
    [picklistValues]
  );

  return { picklistValues, loading, error, refetch, getValues };
}


// ─── Lookup hook (transactional dropdowns) ────────────────────────────────────
// Queries vw_picklist_values_lookup — requires picklists.lookup permission (ESS has it).
// Returns active values only. No `active` or `meta` fields — view intentionally
// omits them. Filter by picklistCode to get values for a specific dropdown.
//
// Usage:
//   const { getValues } = usePicklistValuesLookup();
//   const categories = getValues('EXPENSE_CATEGORY');
//
// NOTE: The existing usePicklistValues() hook is kept for admin picklist management
// screens and any code relying on the `meta` field (e.g. legacy CURRENCY picklist).

export interface PicklistValueLookup {
  id:            string;        // UUID — store as FK on transactions
  picklistCode:  string;        // text code e.g. 'EXPENSE_CATEGORY' — filter by this
  value:         string;        // display label
  refId:         string | null; // optional short code e.g. CAT001
  parentValueId: string | null; // for cascading dropdowns (Country → State → City)
}

interface UsePicklistValuesLookupResult {
  picklistValues: PicklistValueLookup[];
  loading:        boolean;
  error:          string | null;
  /** Convenience: get values for a specific picklist code */
  getValues:      (picklistCode: string) => PicklistValueLookup[];
}

export function usePicklistValuesLookup(): UsePicklistValuesLookupResult {
  const [picklistValues, setPicklistValues] = useState<PicklistValueLookup[]>([]);
  const [loading,        setLoading]        = useState(true);
  const [error,          setError]          = useState<string | null>(null);

  useEffect(() => {
    let mounted = true;
    setLoading(true);
    setError(null);

    supabase
      .from('vw_picklist_values_lookup')
      .select('id, picklist_code, value, ref_id, parent_value_id')
      .order('value', { ascending: true })
      .then(({ data, error: err }) => {
        if (!mounted) return;
        if (err) {
          setError(err.message);
          setPicklistValues([]);
        } else {
          setPicklistValues(
            (data ?? []).map(row => ({
              id:            row.id,
              picklistCode:  row.picklist_code,
              value:         row.value,
              refId:         row.ref_id,
              parentValueId: row.parent_value_id,
            }))
          );
        }
        setLoading(false);
      });

    return () => { mounted = false; };
  }, []);

  const getValues = useCallback(
    (picklistCode: string) =>
      picklistValues.filter(v => v.picklistCode === picklistCode),
    [picklistValues]
  );

  return { picklistValues, loading, error, getValues };
}
