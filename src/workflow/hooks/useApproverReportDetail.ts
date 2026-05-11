/**
 * useApproverReportDetail
 *
 * Fetches a single expense report (header + line items + attachments) by
 * record ID for the approver panel / full-page review. Does NOT filter by
 * ownership — the approver reads any report that has an active task for them.
 *
 * Includes a simple in-memory cache keyed by recordId so switching between
 * task cards doesn't re-fetch data already loaded this session.
 */

import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../../lib/supabase';
import type { LineItem, Attachment } from '../../types';

const BUCKET = 'expense-attachments';

async function makeSignedUrl(path: string): Promise<string> {
  const { data, error } = await supabase.storage
    .from(BUCKET)
    .createSignedUrl(path, 3600);
  if (error || !data?.signedUrl) return '';
  return data.signedUrl;
}

export interface ApproverReportDetail {
  id:               string;
  name:             string;
  employeeName:     string | null;
  status:           string;
  baseCurrencyCode: string;
  submittedAt:      string | null;
  totalConverted:   number;
  lineItems:        LineItem[];
}

interface Result {
  detail:  ApproverReportDetail | null;
  loading: boolean;
  error:   string | null;
  refetch: () => void;
}

export function useApproverReportDetail(recordId: string | null): Result {
  const [detail,  setDetail]  = useState<ApproverReportDetail | null>(null);
  const [loading, setLoading] = useState(false);
  const [error,   setError]   = useState<string | null>(null);
  const [tick,    setTick]    = useState(0);

  const refetch = useCallback(() => {
    setTick(t => t + 1);
  }, []);

  useEffect(() => {
    if (!recordId) {
      setDetail(null);
      setLoading(false);
      setError(null);
      return;
    }

    let mounted = true;
    setLoading(true);
    setError(null);

    async function load() {
      try {
        // ── 1. Reference lookups + report header in parallel ──────────────
        const [rptRes, currRes, pvRes, projRes, empRes] = await Promise.all([
          supabase
            .from('expense_reports')
            .select('id, name, status, base_currency_id, submitted_at, employee_id')
            .eq('id', recordId)
            .single(),
          supabase.from('currencies').select('id, code'),
          supabase.from('picklist_values').select('id, value'),
          supabase.from('projects').select('id, name'),
          supabase.from('employees').select('id, name').is('deleted_at', null),
        ]);

        if (rptRes.error) throw new Error(rptRes.error.message);
        const rpt = rptRes.data;
        if (!rpt) throw new Error('Report not found');

        const currByUUID = new Map((currRes.data ?? []).map((r: any) => [r.id, r.code as string]));
        const catByUUID  = new Map((pvRes.data   ?? []).map((r: any) => [r.id, r.value as string]));
        const projByUUID = new Map((projRes.data  ?? []).map((r: any) => [r.id, r.name as string]));
        const empByUUID  = new Map((empRes.data   ?? []).map((r: any) => [r.id, r.name as string]));

        // ── 2. Line items ─────────────────────────────────────────────────
        const { data: liRows, error: liErr } = await supabase
          .from('line_items')
          .select('id, expense_date, amount, exchange_rate_snapshot, converted_amount, note, currency_id, category_id, project_id')
          .eq('report_id', recordId)
          .order('expense_date', { ascending: true });

        if (liErr) throw new Error(liErr.message);
        const rows = liRows ?? [];

        // ── 3. Attachments (with fresh signed URLs) ───────────────────────
        const lineItemIds = rows.map((li: any) => li.id as string);
        let attStore: Record<string, Attachment[]> = {};

        if (lineItemIds.length > 0) {
          const { data: attRows } = await supabase
            .from('attachments')
            .select('id, line_item_id, file_name, mime_type, size_bytes, storage_path')
            .in('line_item_id', lineItemIds);

          if (attRows?.length) {
            const withUrls = await Promise.all(
              attRows.map(async (row: any) => ({
                lineItemId: row.line_item_id as string,
                attachment: {
                  id:          row.id,
                  name:        row.file_name,
                  type:        row.mime_type,
                  size:        row.size_bytes,
                  dataUrl:     await makeSignedUrl(row.storage_path),
                  storagePath: row.storage_path,
                } satisfies Attachment,
              }))
            );
            attStore = withUrls.reduce<Record<string, Attachment[]>>(
              (acc, { lineItemId, attachment }) => {
                if (!acc[lineItemId]) acc[lineItemId] = [];
                acc[lineItemId].push(attachment);
                return acc;
              }, {}
            );
          }
        }

        // ── 4. Map to frontend types ──────────────────────────────────────
        const lineItems: LineItem[] = rows.map((li: any) => ({
          id:              li.id,
          category:        li.category_id ?? '',
          categoryName:    li.category_id ? (catByUUID.get(li.category_id) ?? '') : '',
          date:            li.expense_date ?? '',
          projectId:       li.project_id ?? undefined,
          projectName:     li.project_id ? (projByUUID.get(li.project_id) ?? undefined) : undefined,
          amount:          Number(li.amount ?? 0),
          currencyCode:    li.currency_id ? (currByUUID.get(li.currency_id) ?? '') : '',
          exchangeRate:    Number(li.exchange_rate_snapshot ?? 1),
          convertedAmount: Number(li.converted_amount ?? 0),
          note:            li.note ?? undefined,
          attachments:     attStore[li.id] ?? [],
        }));

        const totalConverted = lineItems.reduce((s, li) => s + li.convertedAmount, 0);

        const result: ApproverReportDetail = {
          id:               rpt.id,
          name:             rpt.name,
          employeeName:     empByUUID.get(rpt.employee_id) ?? null,
          status:           rpt.status,
          baseCurrencyCode: currByUUID.get(rpt.base_currency_id) ?? '',
          submittedAt:      rpt.submitted_at ?? null,
          totalConverted,
          lineItems,
        };

        if (mounted) { setDetail(result); }
      } catch (err) {
        if (mounted) setError((err as Error).message);
      } finally {
        if (mounted) setLoading(false);
      }
    }

    load();
    return () => { mounted = false; };
  }, [recordId, tick]);

  return { detail, loading, error, refetch };
}
