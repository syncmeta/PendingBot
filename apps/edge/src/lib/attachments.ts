export const IMAGE_MIME_TO_EXT: Record<string, string> = {
  'image/jpeg': 'jpg',
  'image/jpg': 'jpg',
  'image/png': 'png',
  'image/gif': 'gif',
  'image/webp': 'webp',
};

export const MAX_UPLOAD_BYTES = 10 * 1024 * 1024; // 10 MB

// Fallback per-user cloud cap when billing_config.default_attachment_quota_bytes
// is missing. Matches the migration seed (5 GiB) so a wiped config never
// silently disables the quota gate.
export const DEFAULT_ATTACHMENT_QUOTA_BYTES = 5 * 1024 * 1024 * 1024; // 5 GiB

/// SHA-256 hex of the given bytes — used as the content address for
/// per-user dedup on upload. WebCrypto is available in Workers; no
/// node:crypto needed.
export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const buf = await crypto.subtle.digest('SHA-256', bytes as BufferSource);
  const arr = new Uint8Array(buf);
  let out = '';
  for (let i = 0; i < arr.length; i++) {
    out += arr[i].toString(16).padStart(2, '0');
  }
  return out;
}

export function isSupportedImageMime(mime: string): boolean {
  return Object.prototype.hasOwnProperty.call(IMAGE_MIME_TO_EXT, mime.toLowerCase());
}

export function extForMime(mime: string): string {
  return IMAGE_MIME_TO_EXT[mime.toLowerCase()] ?? 'bin';
}

// R2 key shape: yyyy-mm/<uuid>.<ext>
//
// The yyyy-mm bucket prefix groups objects for cheap lifecycle / cleanup
// queries (e.g. "delete orphans older than 90 days from this folder").
export function r2KeyFor(uuid: string, mime: string, ts: number = Date.now()): string {
  const d = new Date(ts);
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, '0');
  return `${y}-${m}/${uuid}.${extForMime(mime)}`;
}
