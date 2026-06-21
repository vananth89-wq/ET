import { useRef, useState } from 'react';
import type { Attachment, LineItem } from '../../../types';

const ALLOWED_TYPES = ['application/pdf', 'image/jpeg', 'image/png'];
const MAX_SIZE = 5 * 1024 * 1024;

interface Props {
  item: LineItem;
  readOnly: boolean;
  onClose: () => void;
  onAdd: (file: File) => Promise<void>;
  onDelete: (attId: string) => Promise<void>;
}

function fmtSize(bytes: number) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1048576).toFixed(1)} MB`;
}

function fileIcon(type: string) {
  if (type === 'application/pdf') return 'fa-file-pdf';
  if (type.startsWith('image/')) return 'fa-file-image';
  return 'fa-file';
}

type UploadState = 'uploading' | 'done' | 'error';

export default function AttachmentModal({ item, readOnly, onClose, onAdd, onDelete }: Props) {
  const fileRef = useRef<HTMLInputElement>(null);
  const [error, setError] = useState('');
  const [dragging, setDragging] = useState(false);
  const [deletingId, setDeletingId] = useState<string | null>(null);
  // Per-file upload tracking
  const [uploadStates, setUploadStates] = useState<Map<string, UploadState>>(new Map());
  const [uploadErrors, setUploadErrors] = useState<Map<string, string>>(new Map());
  const [pendingFiles, setPendingFiles] = useState<Map<string, File>>(new Map());

  const atts = item.attachments ?? [];
  const anyUploading = [...uploadStates.values()].some(s => s === 'uploading');

  async function handleFiles(files: FileList | File[]) {
    setError('');
    const valid = Array.from(files).filter(f => {
      if (!ALLOWED_TYPES.includes(f.type)) { setError('Only PDF, JPG, PNG files are allowed.'); return false; }
      if (f.size > MAX_SIZE) { setError('File exceeds 5 MB limit.'); return false; }
      return true;
    });
    if (valid.length === 0) return;

    // Register pending files with uploading state
    const newPending = new Map(pendingFiles);
    const newStates  = new Map(uploadStates);
    const tempIds: [string, File][] = valid.map(f => [`pending_${Date.now()}_${Math.random().toString(36).slice(2)}`, f]);
    tempIds.forEach(([id, f]) => { newPending.set(id, f); newStates.set(id, 'uploading'); });
    setPendingFiles(newPending);
    setUploadStates(newStates);

    for (const [tempId, file] of tempIds) {
      try {
        await onAdd(file);
        setUploadStates(prev => new Map(prev).set(tempId, 'done'));
        // Remove from pending after short delay so user sees success
        setTimeout(() => {
          setPendingFiles(prev => { const m = new Map(prev); m.delete(tempId); return m; });
          setUploadStates(prev => { const m = new Map(prev); m.delete(tempId); return m; });
        }, 1500);
      } catch (err: any) {
        setUploadStates(prev => new Map(prev).set(tempId, 'error'));
        setUploadErrors(prev => new Map(prev).set(tempId, err?.message ?? 'Upload failed. Please try again.'));
      }
    }

    if (fileRef.current) fileRef.current.value = '';
  }

  async function retryUpload(tempId: string) {
    const file = pendingFiles.get(tempId);
    if (!file) return;
    setUploadStates(prev => new Map(prev).set(tempId, 'uploading'));
    setUploadErrors(prev => { const m = new Map(prev); m.delete(tempId); return m; });
    try {
      await onAdd(file);
      setUploadStates(prev => new Map(prev).set(tempId, 'done'));
      setTimeout(() => {
        setPendingFiles(prev => { const m = new Map(prev); m.delete(tempId); return m; });
        setUploadStates(prev => { const m = new Map(prev); m.delete(tempId); return m; });
      }, 1500);
    } catch (err: any) {
      setUploadStates(prev => new Map(prev).set(tempId, 'error'));
      setUploadErrors(prev => new Map(prev).set(tempId, err?.message ?? 'Upload failed. Please try again.'));
    }
  }

  async function handleDelete(attId: string) {
    setDeletingId(attId);
    try {
      await onDelete(attId);
    } catch (err: any) {
      setError(err?.message ?? 'Delete failed. Please try again.');
    } finally {
      setDeletingId(null);
    }
  }

  function viewFile(att: Attachment) {
    window.open(att.dataUrl, '_blank', 'noopener,noreferrer');
  }

  return (
    <div className="exp-att-overlay" onClick={onClose}>
      <div className="exp-att-modal" onClick={e => e.stopPropagation()}>
        <div className="exp-att-modal-header">
          <span className="exp-att-modal-title"><i className="fa-solid fa-paperclip" /> Attachments</span>
          <button className="exp-att-modal-close" onClick={onClose}><i className="fa-solid fa-xmark" /></button>
        </div>
        <div className="exp-att-modal-body">
          {!readOnly && (
            <div
              className={`exp-att-upload-zone ${dragging ? 'exp-att-upload-zone--drag' : ''} ${anyUploading ? 'exp-att-upload-zone--loading' : ''}`}
              onClick={() => !anyUploading && fileRef.current?.click()}
              onDragOver={e => { e.preventDefault(); if (!anyUploading) setDragging(true); }}
              onDragLeave={() => setDragging(false)}
              onDrop={e => { e.preventDefault(); setDragging(false); if (!anyUploading) handleFiles(e.dataTransfer.files); }}
            >
              {anyUploading
                ? <><i className="fa-solid fa-spinner fa-spin exp-att-upload-icon" /><div className="exp-att-upload-text">Uploading…</div></>
                : <><i className="fa-solid fa-cloud-arrow-up exp-att-upload-icon" /><div className="exp-att-upload-text">Click or drag files here</div><div className="exp-att-upload-hint">PDF, JPG, PNG · max 5 MB per file</div></>
              }
              <input ref={fileRef} type="file" accept=".pdf,.jpg,.jpeg,.png" multiple hidden
                onChange={e => e.target.files && handleFiles(e.target.files)} />
            </div>
          )}
          {error && <div className="exp-att-error">{error}</div>}

          {/* In-progress uploads */}
          {pendingFiles.size > 0 && (
            <div className="exp-att-file-list" style={{ marginBottom: 0 }}>
              <div className="exp-att-file-list-header">UPLOADING</div>
              {[...pendingFiles.entries()].map(([tempId, file]) => {
                const state = uploadStates.get(tempId);
                const errMsg = uploadErrors.get(tempId);
                return (
                  <div key={tempId} className={`exp-att-file-item${state === 'error' ? ' exp-att-file-item--error' : state === 'done' ? ' exp-att-file-item--done' : ''}`}>
                    <i className={`fa-solid ${fileIcon(file.type)} exp-att-file-icon`} />
                    <div className="exp-att-file-info">
                      <div className="exp-att-file-name">{file.name}</div>
                      <div className="exp-att-file-size">{fmtSize(file.size)}</div>
                      {errMsg && <div className="exp-att-file-errmsg">{errMsg}</div>}
                    </div>
                    <div className="exp-att-file-actions">
                      {state === 'uploading' && <span className="exp-att-upload-status--uploading"><i className="fa-solid fa-spinner fa-spin" /> Uploading…</span>}
                      {state === 'done'      && <span className="exp-att-upload-status--done"><i className="fa-solid fa-circle-check" /> Saved</span>}
                      {state === 'error'     && (
                        <button className="exp-att-retry-btn" onClick={() => retryUpload(tempId)}>
                          <i className="fa-solid fa-rotate-right" /> Retry
                        </button>
                      )}
                    </div>
                  </div>
                );
              })}
            </div>
          )}

          {atts.length > 0 && (
            <div className="exp-att-file-list">
              <div className="exp-att-file-list-header">UPLOADED FILES ({atts.length})</div>
              {atts.map(a => (
                <div className="exp-att-file-item" key={a.id}>
                  <i className={`fa-solid ${fileIcon(a.type)} exp-att-file-icon`} />
                  <div className="exp-att-file-info">
                    <div className="exp-att-file-name">{a.name}</div>
                    <div className="exp-att-file-size">{fmtSize(a.size)}</div>
                  </div>
                  <div className="exp-att-file-actions">
                    <button className="exp-att-view-btn" onClick={() => viewFile(a)}>View</button>
                    {!readOnly && (
                      <button
                        className="exp-att-delete-btn"
                        disabled={deletingId === a.id}
                        onClick={() => handleDelete(a.id)}
                      >
                        {deletingId === a.id
                          ? <i className="fa-solid fa-spinner fa-spin" />
                          : <i className="fa-solid fa-trash" />}
                      </button>
                    )}
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
