/**
 * useExpenseData — Supabase-backed expense report hook
 *
 * Reads/writes from:
 *   • expense_reports  (header)
 *   • line_items        (detail rows)
 *   • attachments       (Phase 5: now backed by Supabase Storage)
 *
 * Storage path convention: {employee_uuid}/{report_id}/{line_item_id}/{filename}
 * Signed URLs are generated at load time (1-hour validity) and stored in
 * Attachment.dataUrl so the rest of the UI is unchanged.
 *
 * FK resolution strategy:
 *   • base_currency_id   ← currencies table (code → UUID)
 *   • line_items.currency_id  ← currencies table (code → UUID)
 *   • line_items.category_id  ← passed in as UUID from usePicklistValues
 *   • line_items.project_id   ← passed in as UUID from useProjects
 *   • employee_id (reports)   ← resolved via employees join
 */

import { useState, useEffect, useCallback, useRef } from 'react';
import { supabase } from '../lib/supabase';
import type { ExpenseReport, LineItem, Attachment } from '../types';

const BUCKET = 'expense-attachments';

// ─── Storage helpers ───────────────────────────��──────────────────────────────

/** Upload a File to Storage and return its object path (without bucket prefix). */
async function uploadToStorage(
  employeeUUID: string,
  reportId: string,
  lineItemId: string,
  file: File,
): Promise<string> {
  const ext      = file.name.split('.').pop() ?? 'bin';
  const safeName = `${Date.now()}-${crypto.randomUUID().slice(0, 8)}.${ext}`;
  const path     = `${employeeUUID}/${reportId}/${lineItemId}/${safeName}`;

  const { error } = await supabase.storage.from(BUCKET).upload(path, file, {
    contentType: file.type,
    upsert: false,
  });
  if (error) throw new Error(`Upload failed: ${error.message}`);
  return path;
}

/** Generate a 1-hour signed URL for a storage path. */
async function signedUrl(path: string): Promise<string> {
  const { data, error } = await supabase.storage
    .from(BUCKET)
    .createSignedUrl(path, 3600);
  if (error || !data?.signedUrl) throw new Error(`Could not get download URL: ${error?.message}`);
  return data.signedUrl;
}

/** Load attachments for a set of line item IDs from the DB + generate signed URLs. */
async function loadAttachments(lineItemIds: string[]): Promise<Record<string, Attachment[]>> {
  if (lineItemIds.length === 0) return {};

  const { data, error } = await supabase
    .from('attachments')
    .select('id, line_item_id, file_name, mime_type, size_bytes, storage_path')
    .in('line_item_id', lineItemIds);

  if (error || !data?.length) return {};

  // Generate signed URLs in parallel
  const withUrls = await Promise.all(
    data.map(async (row: any) => {
      let url = '';
      try { url = await signedUrl(row.storage_path); } catch { /* skip broken */ }
      return {
        lineItemId:  row.line_item_id as string,
        attachment: {
          id:          row.id,
          name:        row.file_name,
          type:        row.mime_type,
          size:        row.size_bytes,
          dataUrl:     url,
          storagePath: row.storage_path,
        } satisfies Attachment,
      };
    }),
  );

  // Group by line_item_id
  return withUrls.reduce<Record<string, Attachment[]>>((acc, { lineItemId, attachment }) => {
    if (!acc[lineItemId]) acc[lineItemId] = [];
    acc[lineItemId].push(attachment);
    return acc;
  }, {});
}

// ─── Row → frontend type mappers ─────────────────────────────────────────────

function mapReport(
  row: any,
  lineItemRows: any[],
  empByUUID: Map<string, { employeeId: string; name: string }>,
  currByUUID: Map<string, string>,
  catByUUID:  Map<string, string>,
  projByUUID: Map<string, { name: string }>,
  attStore:   Record<string, Attachment[]>
): ExpenseReport {
  // Resolve employee info
  const emp     = empByUUID.get(row.employee_id);
  const approver = row.approved_by ? empByUUID.get(row.approved_by) : null;
  const rejecter = row.rejected_by ? empByUUID.get(row.rejected_by) : null;

  // Collect line items for this report
  const items = lineItemRows
    .filter((li: any) => li.report_id === row.id)
    .map((li: any) => {
      const liItem: LineItem = {
        id:              li.id,
        category:        li.category_id ?? '',
        categoryName:    li.category_id ? (catByUUID.get(li.category_id) ?? '') : '',
        date:            li.expense_date ?? '',
        projectId:       li.project_id ?? undefined,
        projectName:     li.project_id ? (projByUUID.get(li.project_id)?.name ?? '') : undefined,
        amount:          Number(li.amount ?? 0),
        currencyCode:    li.currency_id ? (currByUUID.get(li.currency_id) ?? '') : '',
        exchangeRate:    Number(li.exchange_rate_snapshot ?? 1),
        convertedAmount: Number(li.converted_amount ?? 0),
        note:            li.note ?? undefined,
        attachments:     attStore[li.id] ?? [],
      };
      return liItem;
    });

  return {
    id:               row.id,
    employeeId:       emp?.employeeId ?? row.employee_id,
    employeeName:     emp?.name,
    name:             row.name,
    status:           row.status,
    baseCurrencyCode: currByUUID.get(row.base_currency_id) ?? '',
    createdAt:        row.created_at,
    updatedAt:        row.updated_at,
    submittedAt:      row.submitted_at ?? undefined,
    approvedAt:       row.approved_at  ?? undefined,
    approvedBy:       approver
                        ? approver.name
                          ? `${approver.name} (${approver.employeeId})`
                          : (approver.employeeId ?? row.approved_by ?? undefined)
                        : (row.approved_by ?? undefined),
    rejectedAt:       row.rejected_at  ?? undefined,
    rejectedBy:       rejecter
                        ? rejecter.name
                          ? `${rejecter.name} (${rejecter.employeeId})`
                          : (rejecter.employeeId ?? row.rejected_by ?? undefined)
                        : (row.rejected_by ?? undefined),
    rejectionReason:  row.rejection_reason ?? undefined,
    lineItems:        items,
  };
}

// ─── Hook ─────────────────────────────────────────────────────────────────────

export interface UseExpenseDataResult {
  reports:          ExpenseReport[];
  loading:          boolean;
  error:            string | null;
  refetch:          () => void;
  getReport:        (id: string) => ExpenseReport | null;
  createReport:     (data: Omit<ExpenseReport, 'id' | 'lineItems'>) => Promise<string>;
  updateReport:     (id: string, patch: Partial<ExpenseReport>) => Promise<void>;
  deleteReport:     (id: string) => Promise<void>;
  addLineItem:      (reportId: string, item: LineItem) => Promise<void>;
  updateLineItem:   (reportId: string, itemId: string, patch: Partial<LineItem>) => Promise<void>;
  deleteLineItem:   (reportId: string, itemId: string) => Promise<void>;
  /**
   * Upload a browser File to Supabase Storage, insert an attachments row,
   * and update local state with the signed URL. Returns the new Attachment.
   */
  addAttachment:    (reportId: string, itemId: string, file: File) => Promise<Attachment>;
  /** Remove an attachment from Storage + DB and update local state. */
  deleteAttachment: (reportId: string, itemId: string, attId: string) => Promise<void>;
  /**
   * Re-fetch line items (and their attachments) for a single report directly
   * from the DB and replace the local state for that report. Call this after
   * closing the edit form to reconcile any drift between optimistic state and
   * what was actually persisted (e.g. if an insert failed but the rollback
   * didn't fire correctly).
   */
  syncReportLineItems: (reportId: string) => Promise<void>;
  /** ESS: draft → submitted. Calls submit_expense() → wf_submit() under the hood. */
  submitReport:     (id: string) => Promise<void>;
  /** ESS: withdraw a submitted report back to draft via the workflow engine. */
  recallReport:     (id: string, reason?: string) => Promise<void>;
}

export function useExpenseData(): UseExpenseDataResult {
  const [reports,  setReports]  = useState<ExpenseReport[]>([]);
  const [loading,  setLoading]  = useState(true);
  const [error,    setError]    = useState<string | null>(null);
  const [tick,     setTick]     = useState(0);

  const refetch = useCallback(() => setTick(t => t + 1), []);

  // Lookup maps — populated during load, used during writes
  const currByCodeRef  = useRef<Map<string, string>>(new Map()); // code  → UUID
  const currByUUIDRef  = useRef<Map<string, string>>(new Map()); // UUID  → code
  const catByUUIDRef   = useRef<Map<string, string>>(new Map()); // UUID  → value string
  const projByUUIDRef  = useRef<Map<string, { name: string }>>(new Map());
  const empByUUIDRef   = useRef<Map<string, { employeeId: string; name: string }>>(new Map());
  const empByCodeRef   = useRef<Map<string, string>>(new Map()); // employeeId code → UUID

  // ── Loader ─────────────────────────────────────────────────────────────────
  useEffect(() => {
    let mounted = true;
    setLoading(true);
    setError(null);

    async function load() {
      try {
        // 1–5. Fire all independent lookups + reports in parallel
        const [
          { data: currRows },
          { data: pvRows },
          { data: projRows },
          { data: empRows },
          { data: rptRows, error: rptErr },
        ] = await Promise.all([
          supabase.from('currencies').select('id, code'),
          supabase.from('picklist_values').select('id, value'),
          supabase.from('projects').select('id, name'),
          supabase.from('employees').select('id, employee_id, name').is('deleted_at', null),
          supabase
            .from('expense_reports')
            .select('id, employee_id, name, status, base_currency_id, submitted_at, approved_at, approved_by, rejected_at, rejected_by, rejection_reason, created_at, updated_at')
            .is('deleted_at', null)
            .order('updated_at', { ascending: false }),
        ]);

        const currByCode = new Map((currRows ?? []).map((r: any) => [r.code, r.id]));
        const currByUUID = new Map((currRows ?? []).map((r: any) => [r.id, r.code]));
        currByCodeRef.current = currByCode;
        currByUUIDRef.current = currByUUID;

        const catByUUID = new Map((pvRows ?? []).map((r: any) => [r.id, r.value]));
        catByUUIDRef.current = catByUUID;

        const projByUUID = new Map((projRows ?? []).map((r: any) => [r.id, { name: r.name }]));
        projByUUIDRef.current = projByUUID;

        const empByUUID = new Map((empRows ?? []).map((r: any) => [r.id, { employeeId: r.employee_id, name: r.name }]));
        const empByCode = new Map((empRows ?? []).map((r: any) => [r.employee_id, r.id]));
        empByUUIDRef.current = empByUUID;
        empByCodeRef.current = empByCode;

        if (rptErr) throw rptErr;

        // 6. Line items (non-deleted) for all fetched reports
        const reportIds = (rptRows ?? []).map((r: any) => r.id);
        let liRows: any[] = [];
        if (reportIds.length > 0) {
          const { data: liData, error: liErr } = await supabase
            .from('line_items')
            .select('id, report_id, expense_date, amount, exchange_rate_snapshot, converted_amount, note, category_id, currency_id, project_id')
            .in('report_id', reportIds)
            .is('deleted_at', null);
          if (liErr) throw liErr;
          liRows = liData ?? [];
        }

        // 7. Load attachments from Supabase Storage (via attachments table + signed URLs)
        const lineItemIds = liRows.map((li: any) => li.id);
        const attStore    = await loadAttachments(lineItemIds);

        // 8. Assemble
        if (!mounted) return;
        const assembled = (rptRows ?? []).map((row: any) =>
          mapReport(row, liRows, empByUUID, currByUUID, catByUUID, projByUUID, attStore)
        );
        setReports(assembled);
        setError(null);
      } catch (err: any) {
        if (!mounted) return;
        setError(err.message ?? 'Failed to load expense data');
        setReports([]);
      } finally {
        if (mounted) setLoading(false);
      }
    }

    load();
    return () => { mounted = false; };
  }, [tick]);

  // ── Helpers for in-memory state updates ────────────────────────────────────

  const patchReport = useCallback((id: string, patch: Partial<ExpenseReport>) => {
    setReports(prev => prev.map(r => r.id === id ? { ...r, ...patch, updatedAt: new Date().toISOString() } : r));
  }, []);

  // ── Read ───────────────────────────────────────────────────────────────────

  const getReport = useCallback((id: string) =>
    reports.find(r => r.id === id) ?? null, [reports]);

  // ── Create report ──────────────────────────────────────────────────────────

  const createReport = useCallback(async (data: Omit<ExpenseReport, 'id' | 'lineItems'>): Promise<string> => {
    const id = crypto.randomUUID();
    const baseCurrencyId = currByCodeRef.current.get(data.baseCurrencyCode);
    // Fall back to first currency in map if code not resolved
    let fallbackCurrId = baseCurrencyId ?? [...currByCodeRef.current.values()][0] ?? '';

    // If still empty (currencies table not readable via RLS for this role),
    // read base_currency_id directly from the employee's own record.
    if (!fallbackCurrId) {
      const { data: { user } } = await supabase.auth.getUser();
      if (user) {
        const { data: profileRow } = await supabase
          .from('profiles')
          .select('employee_id')
          .eq('id', user.id)
          .single();
        if (profileRow?.employee_id) {
          const { data: empRow } = await supabase
            .from('employees')
            .select('base_currency_id')
            .eq('id', profileRow.employee_id)
            .single();
          fallbackCurrId = empRow?.base_currency_id ?? '';
        }
      }
    }

    // Resolve employeeId (human-readable code) → UUID via lookup map.
    // If the map is empty (e.g. employee's profile wasn't linked when the hook
    // first loaded and they couldn't see themselves via RLS), fall back to
    // reading employee_id directly from their own profile row.  This ensures
    // newly-invited employees can create reports without needing a page reload.
    let employeeUUID = empByCodeRef.current.get(data.employeeId) ?? '';
    if (!employeeUUID) {
      const { data: { user } } = await supabase.auth.getUser();
      if (user) {
        const { data: profileRow } = await supabase
          .from('profiles')
          .select('employee_id')
          .eq('id', user.id)
          .single();
        employeeUUID = profileRow?.employee_id ?? '';
      }
    }

    if (!employeeUUID) {
      throw new Error('Your account is not linked to an employee record. Please contact your administrator.');
    }

    if (!fallbackCurrId) {
      throw new Error('No currency found. Please contact your administrator.');
    }

    // Optimistic local update
    const newReport: ExpenseReport = {
      ...data, id, lineItems: [],
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };
    setReports(prev => [newReport, ...prev]);

    // DB write — throw on failure so callers can show the error
    const { error: err } = await supabase
      .from('expense_reports')
      .insert({
        id,
        employee_id:      employeeUUID,
        name:             data.name,
        status:           data.status ?? 'draft',
        base_currency_id: fallbackCurrId,
      });

    if (err) {
      // Roll back optimistic update
      setReports(prev => prev.filter(r => r.id !== id));
      console.error('[useExpenseData] createReport:', err.message);
      throw new Error(err.message);
    }

    return id;
  }, []);

  // ── Update report header ───────────────────────────────────────────────────

  const updateReport = useCallback(async (id: string, patch: Partial<ExpenseReport>): Promise<void> => {
    patchReport(id, patch);

    const dbPatch: Record<string, any> = {};
    if (patch.name)             dbPatch.name   = patch.name;
    if (patch.status)           dbPatch.status = patch.status;
    if (patch.baseCurrencyCode) {
      const cid = currByCodeRef.current.get(patch.baseCurrencyCode);
      if (cid) dbPatch.base_currency_id = cid;
    }
    if (Object.keys(dbPatch).length === 0) return;
    const { error: err } = await supabase.from('expense_reports').update(dbPatch as any).eq('id', id);
    if (err) console.error('[useExpenseData] updateReport:', err.message);
  }, [patchReport]);

  // ── Delete (soft) report ───────────────────────────────────────────────────

  const deleteReport = useCallback(async (id: string): Promise<void> => {
    // Optimistic remove — capture snapshot for rollback
    let snapshot: ExpenseReport | undefined;
    setReports(rs => {
      snapshot = rs.find(r => r.id === id);
      return rs.filter(r => r.id !== id);
    });
    const { error: err } = await supabase.rpc('delete_expense_report', { p_report_id: id });
    if (err) {
      if (snapshot) setReports(rs =>
        [...rs, snapshot!].sort((a, b) =>
          new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime()
        )
      );
      throw new Error(err.message);
    }
  }, []);

  // ── Add line item ──────────────────────────────────────────────────────────

  const addLineItem = useCallback(async (reportId: string, item: LineItem): Promise<void> => {
    // Optimistic: add to local state (single update using functional form)
    setReports(prev => prev.map(r =>
      r.id === reportId
        ? { ...r, lineItems: [...r.lineItems, item], updatedAt: new Date().toISOString() }
        : r
    ));

    // Resolve currency UUID — fall back to DB lookup if ref not populated yet
    let currencyId = currByCodeRef.current.get(item.currencyCode) ?? null;
    if (!currencyId) {
      const { data: cRow } = await supabase
        .from('currencies').select('id').eq('code', item.currencyCode).single();
      currencyId = cRow?.id ?? null;
    }
    if (!currencyId) {
      setReports(prev => prev.map(r =>
        r.id === reportId
          ? { ...r, lineItems: r.lineItems.filter(li => li.id !== item.id) }
          : r
      ));
      throw new Error(`Currency "${item.currencyCode}" not found in database.`);
    }

    const { error: err } = await supabase.from('line_items').insert({
      id:                    item.id,
      report_id:             reportId,
      category_id:           item.category  || null,
      project_id:            item.projectId || null,
      currency_id:           currencyId,
      expense_date:          item.date,
      amount:                item.amount,
      exchange_rate_snapshot: item.exchangeRate,
      converted_amount:      item.convertedAmount,
      note:                  item.note ?? null,
    });
    if (err) {
      // Roll back optimistic update
      setReports(prev => prev.map(r =>
        r.id === reportId
          ? { ...r, lineItems: r.lineItems.filter(li => li.id !== item.id) }
          : r
      ));
      console.error('[useExpenseData] addLineItem:', err.message);
      throw new Error(err.message);
    }

  }, []);

  // ── Update line item ───────────────────────────────────────────────────────

  const updateLineItem = useCallback(async (reportId: string, itemId: string, patch: Partial<LineItem>): Promise<void> => {
    setReports(prev => prev.map(r =>
      r.id === reportId
        ? {
            ...r,
            lineItems:  r.lineItems.map(li => li.id === itemId ? { ...li, ...patch } : li),
            updatedAt: new Date().toISOString(),
          }
        : r
    ));

    const dbPatch: Record<string, any> = {};
    if (patch.category  !== undefined) dbPatch.category_id  = patch.category  || null;
    if (patch.projectId !== undefined) dbPatch.project_id   = patch.projectId || null;
    if (patch.date      !== undefined) dbPatch.expense_date  = patch.date;
    if (patch.amount    !== undefined) dbPatch.amount        = patch.amount;
    if (patch.note      !== undefined) dbPatch.note          = patch.note ?? null;
    if (patch.exchangeRate    !== undefined) dbPatch.exchange_rate_snapshot = patch.exchangeRate;
    if (patch.convertedAmount !== undefined) dbPatch.converted_amount        = patch.convertedAmount;
    if (patch.currencyCode !== undefined) {
      const cid = currByCodeRef.current.get(patch.currencyCode);
      if (cid) dbPatch.currency_id = cid;
    }

    if (Object.keys(dbPatch).length > 0) {
      const { error: err } = await supabase.from('line_items').update(dbPatch as any).eq('id', itemId);
      if (err) console.error('[useExpenseData] updateLineItem:', err.message);
    }

  }, []);

  // ── Delete line item (soft) ────────────────────────────────────────────────

  const deleteLineItem = useCallback(async (reportId: string, itemId: string): Promise<void> => {
    // Remove any storage-backed attachments first
    const report = reports.find(r => r.id === reportId);
    const atts   = report?.lineItems.find(li => li.id === itemId)?.attachments ?? [];
    const storagePaths = atts.map(a => a.storagePath).filter(Boolean) as string[];
    if (storagePaths.length > 0) {
      await supabase.storage.from(BUCKET).remove(storagePaths);
      await supabase.from('attachments').delete().in('id', atts.map(a => a.id));
    }

    setReports(prev => prev.map(r =>
      r.id === reportId
        ? { ...r, lineItems: r.lineItems.filter(li => li.id !== itemId), updatedAt: new Date().toISOString() }
        : r
    ));

    const { error: err } = await supabase
      .from('line_items')
      .update({ deleted_at: new Date().toISOString() })
      .eq('id', itemId);
    if (err) console.error('[useExpenseData] deleteLineItem:', err.message);
  }, [reports]);

  // ── Attachments (Phase 5: Supabase Storage) ───────────────────────────────
  //
  // addAttachment uploads the browser File to the expense-attachments bucket,
  // inserts a row into the attachments table, and updates local state with the
  // signed URL — so all downstream components continue to use att.dataUrl.
  //
  // deleteAttachment removes the object from Storage, deletes the DB row,
  // and patches local state.

  const addAttachment = useCallback(async (
    reportId: string,
    itemId:   string,
    file:     File,
  ): Promise<Attachment> => {
    // Resolve the employee UUID for the storage path (the report's employee_id)
    const report = reports.find(r => r.id === reportId);
    if (!report) throw new Error('Report not found in local state.');

    // employee_id on the report is the human code (e.g. "E001"); we need the UUID.
    // Use the empByCodeRef for the lookup.
    let employeeUUID = empByCodeRef.current.get(report.employeeId) ?? '';
    if (!employeeUUID) {
      // Fallback: read from profiles
      const { data: { user } } = await supabase.auth.getUser();
      if (user) {
        const { data: p } = await supabase
          .from('profiles').select('employee_id').eq('id', user.id).single();
        employeeUUID = p?.employee_id ?? '';
      }
    }
    if (!employeeUUID) throw new Error('Could not resolve employee UUID for storage path.');

    // 1. Upload to Storage
    const storagePath = await uploadToStorage(employeeUUID, reportId, itemId, file);

    // 2. Insert attachments row
    const attId = crypto.randomUUID();
    const { error: dbErr } = await supabase.from('attachments').insert({
      id:           attId,
      line_item_id: itemId,
      file_name:    file.name,
      mime_type:    file.type,
      size_bytes:   file.size,
      storage_path: storagePath,
    });
    if (dbErr) {
      // Roll back the storage upload if DB insert fails
      await supabase.storage.from(BUCKET).remove([storagePath]);
      throw new Error(`Failed to save attachment record: ${dbErr.message}`);
    }

    // 3. Generate signed URL
    const url = await signedUrl(storagePath);

    const att: Attachment = {
      id:          attId,
      name:        file.name,
      type:        file.type,
      size:        file.size,
      dataUrl:     url,
      storagePath,
    };

    // 4. Update local state
    setReports(prev => prev.map(r =>
      r.id === reportId
        ? {
            ...r,
            lineItems: r.lineItems.map(li =>
              li.id === itemId
                ? { ...li, attachments: [...(li.attachments ?? []), att] }
                : li
            ),
            updatedAt: new Date().toISOString(),
          }
        : r
    ));

    return att;
  }, [reports]);

  const deleteAttachment = useCallback(async (
    reportId: string,
    itemId:   string,
    attId:    string,
  ): Promise<void> => {
    // Find the storage path before removing from local state
    const report      = reports.find(r => r.id === reportId);
    const att         = report?.lineItems.find(li => li.id === itemId)
                                ?.attachments?.find(a => a.id === attId);
    const storagePath = att?.storagePath;

    // Optimistic local update
    setReports(prev => prev.map(r =>
      r.id === reportId
        ? {
            ...r,
            lineItems: r.lineItems.map(li =>
              li.id === itemId
                ? { ...li, attachments: (li.attachments ?? []).filter(a => a.id !== attId) }
                : li
            ),
            updatedAt: new Date().toISOString(),
          }
        : r
    ));

    // Remove from Storage (if backed by storage)
    if (storagePath) {
      const { error: storErr } = await supabase.storage.from(BUCKET).remove([storagePath]);
      if (storErr) console.error('[useExpenseData] deleteAttachment storage:', storErr.message);
    }

    // Remove DB row
    const { error: dbErr } = await supabase.from('attachments').delete().eq('id', attId);
    if (dbErr) console.error('[useExpenseData] deleteAttachment db:', dbErr.message);
  }, [reports]);

  // ── Status transitions (Phase 2: RPC-backed workflow) ────────────────────
  //
  // All transitions call SECURITY DEFINER Postgres functions that:
  //   - Lock the row with FOR UPDATE (prevent races)
  //   - Validate ownership / permission scope
  //   - Execute the status transition
  //   - Write an immutable row to expense_approvals
  //
  // We do an optimistic local patch BEFORE the RPC so the UI is instant,
  // then call refetch() to pull the authoritative state back from the DB.
  // On error we revert the optimistic patch and re-throw so callers can
  // surface the server-side error message.

  const submitReport = useCallback(async (id: string): Promise<void> => {
    const prev = reports.find(r => r.id === id);
    patchReport(id, { status: 'submitted', submittedAt: new Date().toISOString() });

    const { error: err } = await supabase.rpc('submit_expense', { p_report_id: id });
    if (err) {
      // Revert optimistic update
      if (prev) patchReport(id, { status: prev.status, submittedAt: prev.submittedAt });
      console.error('[useExpenseData] submitReport:', err.message);
      throw new Error(err.message);
    }
    // Sync authoritative state (approved_at etc may have been set server-side)
    refetch();
  }, [patchReport, refetch, reports]);

  const recallReport = useCallback(async (id: string, reason?: string): Promise<void> => {
    const prev = reports.find(r => r.id === id);
    patchReport(id, { status: 'draft', submittedAt: undefined });

    const { error: err } = await supabase.rpc('wf_withdraw_by_record', {
      p_module_code: 'expense_reports',
      p_record_id:   id,
      p_reason:      reason ?? null,
    });
    if (err) {
      if (prev) patchReport(id, { status: prev.status, submittedAt: prev.submittedAt });
      console.error('[useExpenseData] recallReport:', err.message);
      throw new Error(err.message);
    }
    refetch();
  }, [patchReport, refetch, reports]);

  // ── syncReportLineItems ────────────────────────────────────────────────────
  // Re-reads line items + attachments for a single report from the DB and
  // replaces the local state for that report. This reconciles any drift caused
  // by optimistic updates whose DB inserts failed but whose local-state rollback
  // didn't fire (e.g. mid-flight React Strict Mode double-invoke edge cases).
  const syncReportLineItems = useCallback(async (reportId: string) => {
    const { data: liRows, error: liErr } = await supabase
      .from('line_items')
      .select('id, report_id, expense_date, amount, exchange_rate_snapshot, converted_amount, note, category_id, currency_id, project_id')
      .eq('report_id', reportId)
      .is('deleted_at', null)
      .order('expense_date', { ascending: true });

    if (liErr) {
      console.error('[useExpenseData] syncReportLineItems:', liErr.message);
      return;
    }

    const rows      = liRows ?? [];
    const attStore  = await loadAttachments(rows.map((r: any) => r.id as string));
    const currByUUID = currByUUIDRef.current;
    const catByUUID  = catByUUIDRef.current;
    const projByUUID = projByUUIDRef.current;

    const lineItems: LineItem[] = rows.map((li: any) => ({
      id:              li.id,
      category:        li.category_id ?? '',
      categoryName:    li.category_id ? (catByUUID.get(li.category_id) ?? '') : '',
      date:            li.expense_date ?? '',
      projectId:       li.project_id ?? undefined,
      projectName:     li.project_id ? (projByUUID.get(li.project_id)?.name ?? '') : undefined,
      amount:          Number(li.amount ?? 0),
      currencyCode:    li.currency_id ? (currByUUID.get(li.currency_id) ?? '') : '',
      exchangeRate:    Number(li.exchange_rate_snapshot ?? 1),
      convertedAmount: Number(li.converted_amount ?? 0),
      note:            li.note ?? undefined,
      attachments:     attStore[li.id] ?? [],
    }));

    setReports(prev => prev.map(r =>
      r.id === reportId ? { ...r, lineItems } : r
    ));
  }, []);

  // ─────────────────────────────────────────────────────────────────────────
  return {
    reports, loading, error, refetch,
    getReport,
    createReport, updateReport, deleteReport,
    addLineItem, updateLineItem, deleteLineItem,
    addAttachment, deleteAttachment,
    submitReport, recallReport,
    syncReportLineItems,
  };
}
