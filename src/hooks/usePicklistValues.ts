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
