/**
 * ColorConfig — Admin page for the timesheet color palette.
 *
 * Renders all 11 entity_key rows as an inline-editable grid.
 * Each row shows: label, current color swatch, hex input.
 * A single "Save All" button bulk-updates via upsert_time_color_config().
 * Includes a live preview strip showing all colors together.
 */

import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../../../lib/supabase';
import ErrorBanner from '../../shared/ErrorBanner';

// ─── Types ────────────────────────────────────────────────────────────────────

interface ColorRow {
  entity_key: string;
  color_hex:  string;
  label:      string;
}

// ─── Key groups for visual organisation ──────────────────────────────────────

const GROUPS: { title: string; keys: string[] }[] = [
  {
    title: 'Calendar Day States',
    keys: ['day_underworked', 'day_overworked', 'day_holiday', 'day_leave_full', 'day_leave_partial', 'day_non_working'],
  },
  {
    title: 'Status Badges',
    keys: ['status_draft', 'status_pending', 'status_approved'],
  },
  {
    title: 'Entry Pills',
    keys: ['entry_project', 'entry_time_type'],
  },
];

// ─── Hex validation ───────────────────────────────────────────────────────────

function isValidHex(val: string): boolean {
  return /^#[0-9A-Fa-f]{6}$/.test(val);
}

// ─── Component ────────────────────────────────────────────────────────────────

export default function ColorConfig() {
  const [rows,    setRows]    = useState<ColorRow[]>([]);
  const [edits,   setEdits]   = useState<Record<string, string>>({});
  const [loading, setLoading] = useState(true);
  const [saving,  setSaving]  = useState(false);
  const [error,   setError]   = useState<string | null>(null);
  const [saved,   setSaved]   = useState(false);
  const [hexErrors, setHexErrors] = useState<Record<string, string>>({});

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: e } = await supabase
      .from('time_color_config')
      .select('entity_key, color_hex, label')
      .order('entity_key');
    if (e) { setError(e.message); setLoading(false); return; }
    const rows = (data ?? []) as ColorRow[];
    setRows(rows);
    // Initialize edits from DB values
    const init: Record<string, string> = {};
    rows.forEach(r => { init[r.entity_key] = r.color_hex; });
    setEdits(init);
    setLoading(false);
  }, []);

  useEffect(() => { const t = setTimeout(load, 0); return () => clearTimeout(t); }, [load]);

  function handleHexChange(key: string, val: string) {
    setEdits(p => ({ ...p, [key]: val }));
    setHexErrors(p => ({ ...p, [key]: isValidHex(val) ? '' : 'Must be a valid #rrggbb hex color.' }));
    setSaved(false);
  }

  function handleSwatchChange(key: string, val: string) {
    // Native color picker always gives valid hex
    setEdits(p => ({ ...p, [key]: val }));
    setHexErrors(p => ({ ...p, [key]: '' }));
    setSaved(false);
  }

  async function handleSave() {
    // Validate all
    const errs: Record<string, string> = {};
    for (const [key, val] of Object.entries(edits)) {
      if (!isValidHex(val)) errs[key] = 'Invalid hex.';
    }
    if (Object.keys(errs).length) { setHexErrors(errs); return; }

    setSaving(true);
    const payload = Object.entries(edits).map(([entity_key, color_hex]) => ({ entity_key, color_hex }));
    const { data, error: e } = await supabase.rpc('upsert_time_color_config', { p_configs: payload });
    setSaving(false);

    if (e || !data?.ok) {
      setError(data?.message ?? e?.message ?? 'Unknown error.');
      return;
    }
    setSaved(true);
    await load();
    setTimeout(() => setSaved(false), 3000);
  }

  function resetAll() {
    const init: Record<string, string> = {};
    rows.forEach(r => { init[r.entity_key] = r.color_hex; });
    setEdits(init);
    setHexErrors({});
    setSaved(false);
  }

  const hasChanges = rows.some(r => edits[r.entity_key] !== r.color_hex);

  // ── Render ────────────────────────────────────────────────────────────────

  if (loading) {
    return (
      <div className="ar-panel" style={{ textAlign: 'center', padding: 40, color: '#9CA3AF' }}>
        <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 8 }} />Loading color config…
      </div>
    );
  }

  return (
    <div className="ar-panel">
      <h2 className="page-title">Color Configuration</h2>
      <p className="page-subtitle">
        Customise the colors used across timesheet calendar cells, status badges, and entry pills.
        Use the color picker or type a hex code directly.
      </p>

      {error && <ErrorBanner message={error} onRetry={load} />}

      {/* ── Live preview strip ──────────────────────────────────────────────── */}
      <div style={{
        background: '#F9FAFB', border: '1px solid #E5E7EB', borderRadius: 8,
        padding: '12px 16px', marginBottom: 28,
      }}>
        <div style={{ fontSize: 12, fontWeight: 600, color: '#6B7280', marginBottom: 10, textTransform: 'uppercase' }}>
          Live Preview
        </div>
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          {rows.map(r => (
            <div key={r.entity_key}
              title={r.label}
              style={{
                width: 32, height: 32, borderRadius: 6,
                background: isValidHex(edits[r.entity_key] ?? '') ? edits[r.entity_key] : r.color_hex,
                border: '1px solid rgba(0,0,0,0.08)',
                cursor: 'default',
              }}
            />
          ))}
        </div>
      </div>

      {/* ── Color groups ────────────────────────────────────────────────────── */}
      {GROUPS.map(group => {
        const groupRows = rows.filter(r => group.keys.includes(r.entity_key));
        if (!groupRows.length) return null;
        return (
          <div key={group.title} style={{ marginBottom: 28 }}>
            <div style={{
              fontSize: 12, fontWeight: 700, color: '#374151', textTransform: 'uppercase',
              letterSpacing: '0.06em', marginBottom: 10, paddingBottom: 6,
              borderBottom: '1px solid #E5E7EB',
            }}>
              {group.title}
            </div>

            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              {groupRows.map(row => {
                const current = edits[row.entity_key] ?? row.color_hex;
                const hexErr  = hexErrors[row.entity_key];
                return (
                  <div key={row.entity_key} style={{
                    display: 'grid', gridTemplateColumns: '220px 44px 140px 1fr',
                    alignItems: 'center', gap: 12,
                    padding: '8px 12px', borderRadius: 6,
                    background: '#FFFFFF', border: '1px solid #F3F4F6',
                  }}>
                    {/* Label */}
                    <div style={{ fontSize: 13, fontWeight: 500, color: '#374151' }}>
                      {row.label}
                    </div>

                    {/* Color swatch / native picker */}
                    <label style={{ cursor: 'pointer' }} title="Click to open color picker">
                      <div style={{
                        width: 32, height: 32, borderRadius: 6,
                        background: isValidHex(current) ? current : '#CCCCCC',
                        border: '2px solid #D1D5DB',
                        overflow: 'hidden', position: 'relative',
                      }}>
                        <input
                          type="color"
                          value={isValidHex(current) ? current : '#cccccc'}
                          onChange={e => handleSwatchChange(row.entity_key, e.target.value)}
                          style={{
                            opacity: 0, position: 'absolute', inset: 0,
                            width: '100%', height: '100%', cursor: 'pointer',
                          }}
                        />
                      </div>
                    </label>

                    {/* Hex input */}
                    <div>
                      <input
                        type="text"
                        value={current}
                        onChange={e => handleHexChange(row.entity_key, e.target.value)}
                        maxLength={7}
                        style={{
                          padding: '5px 10px', borderRadius: 6, fontSize: 13,
                          fontFamily: 'monospace',
                          border: `1px solid ${hexErr ? '#EF4444' : '#D1D5DB'}`,
                          width: 110,
                        }}
                      />
                      {hexErr && <div style={{ fontSize: 11, color: '#EF4444', marginTop: 2 }}>{hexErr}</div>}
                    </div>

                    {/* Entity key chip */}
                    <code style={{ fontSize: 11, color: '#9CA3AF', background: '#F3F4F6', padding: '2px 6px', borderRadius: 4 }}>
                      {row.entity_key}
                    </code>
                  </div>
                );
              })}
            </div>
          </div>
        );
      })}

      {/* ── Save bar ────────────────────────────────────────────────────────── */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: 12,
        paddingTop: 16, borderTop: '1px solid #E5E7EB',
      }}>
        <button className="btn-add" onClick={handleSave} disabled={saving || !hasChanges}>
          {saving
            ? <><i className="fa-solid fa-spinner fa-spin" /> Saving…</>
            : <><i className="fa-solid fa-floppy-disk" /> Save Colors</>
          }
        </button>

        {hasChanges && (
          <button className="btn-cancel" onClick={resetAll} disabled={saving}>
            Reset
          </button>
        )}

        {saved && !hasChanges && (
          <span style={{ color: '#10B981', fontSize: 13, display: 'flex', alignItems: 'center', gap: 6 }}>
            <i className="fa-solid fa-circle-check" /> Colors saved
          </span>
        )}
      </div>
    </div>
  );
}
