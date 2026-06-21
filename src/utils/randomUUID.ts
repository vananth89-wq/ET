/**
 * randomUUID — cross-context UUID v4 generator.
 *
 * crypto.randomUUID() requires a secure context (HTTPS).
 * On plain HTTP (e.g. local network dev at 192.168.x.x), it throws.
 * This utility falls back to a Math.random-based v4 UUID so the app
 * works in both HTTP and HTTPS environments.
 */
export function randomUUID(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID();
  }
  // RFC 4122 v4 UUID fallback using Math.random
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
    const r = (Math.random() * 16) | 0;
    const v = c === 'x' ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}
