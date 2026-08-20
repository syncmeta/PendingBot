export const IMAGE_MIME_TO_EXT: Record<string, string> = {
  'image/jpeg': 'jpg',
  'image/jpg': 'jpg',
  'image/png': 'png',
  'image/gif': 'gif',
  'image/webp': 'webp',
};

// Single-file upload cap. Applies to every MIME type — images, PDFs,
// archives, audio, code, anything. 25 MB is the product-confirmed limit
// (images used to be capped at 10 MB; this supersedes that). The
// per-user cloud quota below is unchanged at 1 GiB.
export const MAX_UPLOAD_BYTES = 25 * 1024 * 1024; // 25 MB

// Fallback per-user cloud cap when billing_config.default_attachment_quota_bytes
// is missing, so a wiped config never silently disables the quota gate.
// Must match the billing_config seed in migration 20260512043115, so a fresh
// prod DB and a wiped config agree on the cap.
export const DEFAULT_ATTACHMENT_QUOTA_BYTES = 1 * 1024 * 1024 * 1024; // 1 GiB

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

export function isPdfMime(mime: string): boolean {
  return mime.toLowerCase().split(';')[0]!.trim() === 'application/pdf';
}

/// How an attachment is fed to the LLM:
///   - 'image' → image_url content part (vision models) + vision summary
///   - 'pdf'   → file content part, parsed natively by the provider
///   - 'file'  → not sent inline; listed in the attachment inventory and
///               fetched on demand via the read_attachment tool
export type AttachmentKind = 'image' | 'pdf' | 'file';

export function classifyAttachment(mime: string): AttachmentKind {
  if (isSupportedImageMime(mime)) return 'image';
  if (isPdfMime(mime)) return 'pdf';
  return 'file';
}

export function extForMime(mime: string): string {
  return IMAGE_MIME_TO_EXT[mime.toLowerCase()] ?? 'bin';
}

// R2 key shape (legacy, kept exported only for the orphan-sweep tests
// that exercise the prefix grouping behavior): yyyy-mm/<uuid>.<ext>.
//
// Live uploads use r2KeyForHash below — content-addressable so two
// users uploading the same bytes share one R2 object. This function
// is retained as a fallback for callers that need a per-row UUID key
// (currently none; see attachments.test.ts for the pinned shape).
export function r2KeyFor(uuid: string, mime: string, ts: number = Date.now()): string {
  const d = new Date(ts);
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, '0');
  return `${y}-${m}/${uuid}.${extForMime(mime)}`;
}

// Content-addressable R2 key — used by the upload path so cross-user
// duplicate uploads (e.g. the same forwarded meme image landing in two
// users' attachment libraries) collapse onto one R2 object. The
// attachments table still gets a per-user row each time (preserving
// recall, quota accounting, and per-user privacy boundaries), but the
// underlying bytes are stored once.
//
// Shape: `blobs/<sha256-hex>.<ext>`. The prefix lets the orphan-sweep
// cron glob `blobs/*` independently of the legacy `yyyy-mm/*` keys
// while still being a single shared namespace across all users.
//
// `attachments.r2_key` is what /v1/uploads/:id reads to GET the body,
// so it must always match the actual R2 object. The (user_id,
// content_sha256) UNIQUE index in migration 20260512052048 still
// short-circuits per-user dedup; this function only fires when a row
// is being created for the first time.
export function r2KeyForHash(contentSha256: string, mime: string): string {
  return `blobs/${contentSha256}.${extForMime(mime)}`;
}
