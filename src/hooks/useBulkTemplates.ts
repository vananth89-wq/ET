/**
 * useBulkTemplates
 *
 * Fetches bulk_template_registry rows that the current user has at least
 * one bulk permission for (import OR export). Drives the template dropdown
 * and the Permission Matrix IMPORT/EXPORT band.
 */

import { useState, useEffect } from 'react';
import { supabase }            from '../lib/supabase';
import { usePermissions }      from './usePermissions';

export interface BulkTemplateRow {
  template_code:     string;
  display_label:     string;
  description:       string;
  icon:              string;
  sort_order:        number;
  permission_import: string;
  permission_export: string;
  processor_rpc:     string;
  schema_definition: {
    columns:       ColumnDef[];
    natural_key:   string[];
    row_processor: 'per_row' | 'group_by_key';
    group_by?:     string[];
  };
  natural_key:       string[];
}

interface ColumnDef {
  name:                        string;
  data_type:                   string;
  mandatory:                   boolean;
  user_fillable:               boolean;
  description?:                string;
  include_with_system_metadata?: boolean;
  computed_from?:              string;
}

export function useBulkTemplates() {
  const { can, permissionsLoading } = usePermissions();
  const [templates, setTemplates]   = useState<BulkTemplateRow[]>([]);
  const [loading, setLoading]       = useState(true);
  const [error, setError]           = useState<string | null>(null);

  useEffect(() => {
    if (permissionsLoading) return;

    async function load() {
      setLoading(true);
      setError(null);

      const { data, error: err } = await supabase
        .from('bulk_template_registry')
        .select('*')
        .eq('is_active', true)
        .order('sort_order');

      if (err) {
        setError(err.message);
        setLoading(false);
        return;
      }

      // Filter to rows where user has import OR export permission
      const visible = (data ?? []).filter(
        (t: BulkTemplateRow) =>
          can(t.permission_import) || can(t.permission_export)
      );

      setTemplates(visible);
      setLoading(false);
    }

    load();
  }, [permissionsLoading, can]);

  /** All 30 bulk permission codes — used by Permission Matrix band */
  function allBulkPermissions(): string[] {
    return templates.flatMap(t => [t.permission_import, t.permission_export]);
  }

  return { templates, loading, error, allBulkPermissions };
}
