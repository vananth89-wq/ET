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

export default function AttachmentModal({ item, readOnly, onClose, onAdd, onDelete }: Props) {
  const fileRef = useRef<HTMLInputElement>(null);
  const [error, setError] = useState('');
  const [dragging, setDragging] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [deletingId, setDeletingId] = useState<string | null>(null);
  const atts = item.attachments ?? [];

  async function handleFiles(files: FileList | File[]) {
    setError('');
    const valid = Array.from(files).filter(f => {
      if (!ALLOWED_TYPES.includes(f.type)) { setError('Only PDF, JPG, PNG files are allowed.'); return false; }
      if (f.size > MAX_SIZE) { setError('File exceeds 5 MB limit.'); return false; }
      return true;
    });
    if (valid.length === 0) return;
    setUploading(true);
    try {
      for (const f of valid) {
        await onAdd(f);
      }
    } catch (err: any) {
      setError(err?.message ?? 'Upload failed. Please try again.');
    } finally {
      setUploading(false);
      if (fileRef.current) fileRef.current.value = '';
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
              className={`exp-att-upload-zone ${dragging ? 'exp-att-upload-zone--drag' : ''} ${uploading ? 'exp-att-upload-zone--loading' : ''}`}
              onClick={() => !uploading && fileRef.current?.click()}
              onDragOver={e => { e.preventDefault(); if (!uploading) setDragging(true); }}
              onDragLeave={() => setDragging(false)}
              onDrop={e => { e.preventDefault(); setDragging(false); if (!uploading) handleFiles(e.dataTransfer.files); }}
            >
              {uploading
                ? <><i className="fa-solid fa-spinner fa-spin exp-att-upload-icon" /><div className="exp-att-upload-text">Uploading…</div></>
                : <><i className="fa-solid fa-cloud-arrow-up exp-att-upload-icon" /><div className="exp-att-upload-text">Click or drag files here</div><div className="exp-att-upload-hint">PDF, JPG, PNG · max 5 MB per file</div></>
              }
              <input ref={fileRef} type="file" accept=".pdf,.jpg,.jpeg,.png" multiple hidden
                onChange={e => e.target.files && handleFiles(e.target.files)} />
            </div>
          )}
          {error && <div className="exp-att-error">{error}</div>}
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
