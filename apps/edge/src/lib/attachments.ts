export const IMAGE_MIME_TO_EXT: Record<string, string> = {
  'image/jpeg': 'jpg',
  'image/jpg': 'jpg',
  'image/png': 'png',
  'image/gif': 'gif',
  'image/webp': 'webp',
};

export const MAX_UPLOAD_BYTES = 10 * 1024 * 1024; // 10 MB

// Fallback per-user cloud cap when billing_config.default_attachment_quota_bytes
// is missing. Matches the migration seed (1 GiB) so a wiped config never
// silently disables the quota gate.
export const DEFAULT_ATTACHMENT_QUOTA_BYTES = 1024 * 1024 * 1024; // 1 GiB

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
