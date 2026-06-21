/**
 * DeactivationImpactModal
 *
 * Shown before submitting a status change that will deactivate an employee.
 * Calls get_deactivation_impact() to list every employee where the target
 * person is currently a matrix manager, so HR sees the blast radius before
 * confirming.
 *
 * Design spec: docs/job-relationships-design.md §7
 *
 * Props:
 *   employeeId   — UUID of the employee being deactivated
 *   employeeName — display name for the dialog title
 *   onConfirm    — called when HR clicks "Deactivate Anyway"
 *   onCancel     — called when HR cancels
 */

import { useState, useEffect } from 'react';
import { supabase } from '../../lib/supabase';

interface AffectedEmployee {
  employee_id:   string;
  employee_code: string;
  name:          string;
  codes_held:    string[];
}

interface DeactivationImpactModalProps {
  employeeId:   string;
  employeeName: string;
  onConfirm:    () => void;
  onCancel:     () => void;
}

const JR_CODE_LABELS: Record<string, string> = {
  PM01: 'Project Manager',
  PM02: 'Programme Manager',
  PM03: 'Practice Manager',
  OM01: 'Operations Manager',
  OM02: 'Operations Lead',
  OM03: 'Operations Coordinator',
};

export default function DeactivationImpactModal({
  employeeId,
  employeeName,
  onConfirm,
  onCancel,
}: DeactivationImpactModalProps) {
  const [affected, setAffected] = useState<AffectedEmployee[]>([]);
  const [total,    setTotal]    = useState(0);
  const [loading,  setLoading]  = useState(true);
  const [error,    setError]    = useState('');
  const [expanded, setExpanded] = useState(false);

  useEffect(() => {
    (async () => {
      const { data, error: err } = await supabase.rpc('get_deactivation_impact', {
        p_employee_id: employeeId,
      });
      if (err) { setError(err.message); setLoading(false); return; }
      const payload = data as {
        ok: boolean;
        affected_employees: AffectedEmployee[];
        total: number;
      } | null;
      setAffected(payload?.affected_employees ?? []);
      setTotal(payload?.total ?? 0);
      setLoading(false);
    })();
  }, [employeeId]);

  const PREVIEW_COUNT = 5;
  const preview = expanded ? affected : affected.slice(0, PREVIEW_COUNT);
  const hasMore  = affected.length > PREVIEW_COUNT;

  return (
    <div style={{
      position: 'fixed', inset: 0,
      background: 'rgba(0,0,0,0.5)',
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      zIndex: 2000,
    }}>
      <div style={{
        background: '#fff', borderRadius: 12,
        width: 520, maxHeight: '80vh',
        display: 'flex', flexDirection: 'column',
        boxShadow: '0 20px 60px rgba(0,0,0,0.2)',
        overflow: 'hidden',
      }}>
        {/* Header */}
        <div style={{
          padding: '20px 24px 16px',
          borderBottom: '1px solid #E5E7EB',
        }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 6 }}>
            <div style={{
              width: 36, height: 36, borderRadius: '50%',
              background: '#FEE2E2', display: 'flex', alignItems: 'center', justifyContent: 'center',
              flexShrink: 0,
            }}>
              <i className="fa-solid fa-triangle-exclamation" style={{ color: '#DC2626', fontSize: 16 }} />
            </div>
            <h2 style={{ margin: 0, fontSize: 16, fontWeight: 700, color: '#111827' }}>
              Confirm Deactivation
            </h2>
          </div>
          <p style={{ margin: 0, fontSize: 13.5, color: '#374151', lineHeight: 1.5 }}>
            You are about to deactivate <strong>{employeeName}</strong>.
          </p>
        </div>

        {/* Body */}
        <div style={{ flex: 1, overflowY: 'auto', padding: '16px 24px' }}>
          {loading ? (
            <div style={{ textAlign: 'center', padding: '24px 0', color: '#6B7280', fontSize: 13 }}>
              <i className="fa-solid fa-spinner fa-spin" style={{ marginRight: 6 }} />
              Checking impact…
            </div>
          ) : error ? (
            <div style={{ color: '#DC2626', fontSize: 13 }}>
              <i className="fa-solid fa-circle-exclamation" style={{ marginRight: 6 }} />
              {error}
            </div>
          ) : total === 0 ? (
            <div style={{
              padding: '14px 16px',
              background: '#F0FDF4', borderRadius: 8,
              border: '1px solid #BBF7D0',
              fontSize: 13.5, color: '#166534',
              display: 'flex', alignItems: 'center', gap: 8,
            }}>
              <i className="fa-solid fa-circle-check" />
              <span>
                <strong>{employeeName}</strong> is not a matrix manager for any employee.
                Deactivation will not affect any job relationships.
              </span>
            </div>
          ) : (
            <>
              <div style={{
                padding: '12px 16px',
                background: '#FFF7ED', borderRadius: 8,
                border: '1px solid #FED7AA',
                fontSize: 13.5, color: '#92400E',
                marginBottom: 14,
              }}>
                <i className="fa-solid fa-triangle-exclamation" style={{ marginRight: 6, color: '#D97706' }} />
                <strong>{employeeName}</strong> is a matrix manager for{' '}
                <strong>{total} employee{total !== 1 ? 's' : ''}</strong>.
                Deactivating will automatically remove these matrix assignments.
                You may want to reassign them first.
              </div>

              <div style={{ marginBottom: 8, fontSize: 12, fontWeight: 600, color: '#6B7280', textTransform: 'uppercase', letterSpacing: '0.05em' }}>
                Affected Employees
              </div>

              <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                {preview.map(emp => (
                  <div key={emp.employee_id} style={{
                    padding: '10px 14px',
                    background: '#F9FAFB', borderRadius: 8,
                    border: '1px solid #E5E7EB',
                    display: 'flex', justifyContent: 'space-between', alignItems: 'center',
                  }}>
                    <div>
                      <span style={{ fontSize: 13, fontWeight: 600, color: '#111827' }}>{emp.name}</span>
                      <span style={{ fontSize: 12, color: '#6B7280', marginLeft: 8 }}>({emp.employee_code})</span>
                    </div>
                    <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap', justifyContent: 'flex-end' }}>
                      {emp.codes_held.map(code => (
                        <span key={code} style={{
                          fontSize: 11, fontWeight: 600,
                          background: '#EEF2FF', color: '#4F46E5',
                          borderRadius: 10, padding: '2px 8px',
                        }} title={JR_CODE_LABELS[code] ?? code}>
                          {code}
                        </span>
                      ))}
                    </div>
                  </div>
                ))}
              </div>

              {hasMore && !expanded && (
                <button
                  onClick={() => setExpanded(true)}
                  style={{
                    background: 'none', border: 'none', cursor: 'pointer',
                    color: '#4F46E5', fontSize: 12.5, marginTop: 8,
                    display: 'flex', alignItems: 'center', gap: 4,
                  }}
                >
                  <i className="fa-solid fa-chevron-down" style={{ fontSize: 10 }} />
                  Show {affected.length - PREVIEW_COUNT} more…
                </button>
              )}

              <p style={{ fontSize: 12.5, color: '#6B7280', marginTop: 12, lineHeight: 1.5 }}>
                The deactivation fanout will automatically close all matrix-manager sets that
                reference <strong>{employeeName}</strong>. Removed assignments are never
                auto-restored if the employee is later reactivated.
              </p>
            </>
          )}
        </div>

        {/* Footer */}
        <div style={{
          padding: '14px 24px',
          borderTop: '1px solid #E5E7EB',
          display: 'flex', justifyContent: 'flex-end', gap: 8,
          background: '#F9FAFB',
        }}>
          <button
            onClick={onCancel}
            disabled={loading}
            style={{
              padding: '8px 18px', fontSize: 13, borderRadius: 6,
              border: '1px solid #D1D5DB', background: '#fff',
              cursor: 'pointer', color: '#374151', fontWeight: 500,
            }}
          >
            Cancel
          </button>
          <button
            onClick={onConfirm}
            disabled={loading}
            style={{
              padding: '8px 18px', fontSize: 13, borderRadius: 6,
              background: '#DC2626', color: '#fff', border: 'none',
              cursor: 'pointer', fontWeight: 600,
              display: 'flex', alignItems: 'center', gap: 6,
            }}
          >
            <i className="fa-solid fa-user-slash" />
            Deactivate Anyway
          </button>
        </div>
      </div>
    </div>
  );
}
