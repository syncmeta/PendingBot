// send_images — the bot's "throw this picture into the chat" tool.
//
// Not image generation. The bot already has the bytes (from a tool
// result, a public URL it knows, or a data URL it composed) and just
// wants to put them in front of the user. Terminal: when this fires,
// the round loop in bot-reply/index.ts breaks — there's no follow-up
// LLM turn, the act of calling the tool *is* the send.
//
// Inputs: 1–5 entries, each either
//   • https? URL  → fetched server-side (SSRF-guarded, 25 MB cap)
//   • data:image/<mime>;base64,<b64> URI
//
// Outputs: one messages row carrying `attachments: { ids: [...] }`,
// inserted via ctx.emitImagesMessage so the bot-reply closure controls
// bubbleGroupId / sender_bot_id / model_slug.
//
// MIME is locked to the four common image kinds (png / jpeg / webp /
// gif). The model trying to attach a PDF or an mp4 here is a bug —
// the tool is named send_images, not send_files.

import type { Env } from '../../../types';
import type { ToolCtx } from '../tool-runner';
import { IMAGE_MIME_TO_EXT, MAX_UPLOAD_BYTES } from '../../attachments';
import { persistAttachmentBytes } from '../../attachments-persist';
import { serviceClient } from '../../supabase';

const MAX_IMAGES = 5;
const FETCH_TIMEOUT_MS = 8_000;

// Magic-byte sniff for the four allowed types. Used when an http(s)
// fetch returns a generic Content-Type (`application/octet-stream`) or
// no header at all, and to validate that a data: URL's claimed MIME
// actually matches the bytes. Returns null on no match.
// Exported for unit tests; rest of the module uses it directly.
export function sniffImageMime(bytes: Uint8Array): string | null {
  if (bytes.length >= 8 &&
      bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47 &&
      bytes[4] === 0x0d && bytes[5] === 0x0a && bytes[6] === 0x1a && bytes[7] === 0x0a) {
    return 'image/png';
  }
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return 'image/jpeg';
  }
  if (bytes.length >= 12 &&
      bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46 &&
      bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50) {
    return 'image/webp';
  }
  if (bytes.length >= 6 &&
      bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x38 &&
      (bytes[4] === 0x37 || bytes[4] === 0x39) && bytes[5] === 0x61) {
    return 'image/gif';
  }
  return null;
}

function normalizeMime(raw: string): string {
  const m = raw.toLowerCase().split(';')[0]!.trim();
  if (m === 'image/jpg') return 'image/jpeg';
  return m;
}

// SSRF hostname filter. Workers fetch already refuses some internal
// routes, but a hostile URL with a public-looking host can still
// resolve to a private RFC1918 / link-local target post-DNS, and we
// don't get to see the resolved IP here. So we block the obvious
// literal-IP attacks and the well-known internal hostnames. The
// remaining attack surface (a DNS name that resolves to a private IP)
// is what Cloudflare's own egress restrictions cover.
export function isBlockedHost(hostname: string): boolean {
  const h = hostname.toLowerCase().replace(/^\[|\]$/g, '');
  if (h === 'localhost' || h.endsWith('.localhost')) return true;
  if (h === 'metadata.google.internal') return true;
  // IPv4 literal
  const v4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(h);
  if (v4) {
    const a = Number(v4[1]), b = Number(v4[2]);
    if (a === 10) return true;
    if (a === 127) return true;
    if (a === 0) return true;
    if (a === 169 && b === 254) return true;            // link-local + AWS/GCP metadata 169.254.169.254
    if (a === 172 && b >= 16 && b <= 31) return true;   // private
    if (a === 192 && b === 168) return true;
    if (a >= 224) return true;                          // multicast + reserved
    return false;
  }
  // IPv6 literal — block loopback, link-local, ULA, unspecified.
  if (h.includes(':')) {
    if (h === '::1' || h === '::') return true;
    if (h.startsWith('fe80:') || h.startsWith('fc') || h.startsWith('fd')) return true;
    return false;
  }
  return false;
}

export interface FetchedImage {
  bytes: Uint8Array;
  mime: string;
}

// Decode a `data:image/<mime>;base64,<payload>` URI to bytes. Throws
// on malformed input or unsupported MIME.
export function decodeDataUrl(dataUrl: string): FetchedImage {
  const head = dataUrl.slice(0, dataUrl.indexOf(','));
  const body = dataUrl.slice(dataUrl.indexOf(',') + 1);
  if (!head.startsWith('data:')) throw new Error('not a data: URL');
  const meta = head.slice('data:'.length); // e.g. image/png;base64
  const parts = meta.split(';');
  const rawMime = parts[0] || 'application/octet-stream';
  const isBase64 = parts.includes('base64');
  if (!isBase64) throw new Error('only base64 data URLs are accepted');
  const claimed = normalizeMime(rawMime);
  if (!IMAGE_MIME_TO_EXT[claimed]) {
    throw new Error(`unsupported image MIME: ${claimed}`);
  }
  let bin: string;
  try { bin = atob(body); } catch { throw new Error('invalid base64 payload'); }
  if (bin.length > MAX_UPLOAD_BYTES) {
    throw new Error(`image exceeds ${MAX_UPLOAD_BYTES} bytes`);
  }
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  // Trust bytes over header: sniff overrides the claimed MIME when they
  // disagree. Skip the sniff for tiny inputs (they'll be rejected by the
  // unknown-MIME branch in the runner anyway).
  const sniffed = sniffImageMime(bytes);
  if (sniffed && sniffed !== claimed) {
    return { bytes, mime: sniffed };
  }
  return { bytes, mime: claimed };
}

// Fetch a public URL into bytes with a hard size cap (drains chunks
// and aborts once cumulative bytes exceed MAX_UPLOAD_BYTES) and a
// global timeout. SSRF guard applies before any network call.
async function fetchPublicImage(
  url: string,
  signal: AbortSignal,
): Promise<FetchedImage> {
  let u: URL;
  try { u = new URL(url); } catch { throw new Error('invalid URL'); }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') {
    throw new Error('only http(s) URLs are accepted');
  }
  if (isBlockedHost(u.hostname)) {
    throw new Error(`blocked host: ${u.hostname}`);
  }

  // Compose timeout signal with caller's abort. Either firing aborts
  // the fetch.
  const ac = new AbortController();
  const onAbort = () => ac.abort();
  signal.addEventListener('abort', onAbort, { once: true });
  const timeout = setTimeout(() => ac.abort(), FETCH_TIMEOUT_MS);

  let res: Response;
  try {
    res = await fetch(u.toString(), {
      signal: ac.signal,
      redirect: 'follow',
      // No credentials; this is an outbound fetch, not a bot-on-behalf
      // request. Don't leak any ambient auth.
      headers: { Accept: 'image/*' },
    });
  } catch (err) {
    clearTimeout(timeout);
    signal.removeEventListener('abort', onAbort);
    const msg = err instanceof Error ? err.message : String(err);
    throw new Error(`fetch failed: ${msg}`);
  } finally {
    clearTimeout(timeout);
    signal.removeEventListener('abort', onAbort);
  }

  if (!res.ok) throw new Error(`fetch returned ${res.status}`);

  // Honour Content-Length if the server advertises it: bail before
  // we burn memory on an oversized payload.
  const cl = res.headers.get('content-length');
  if (cl) {
    const n = Number(cl);
    if (Number.isFinite(n) && n > MAX_UPLOAD_BYTES) {
      throw new Error(`image exceeds ${MAX_UPLOAD_BYTES} bytes`);
    }
  }

  // Streamed read with cumulative cap — Content-Length is advisory.
  const reader = res.body?.getReader();
  if (!reader) throw new Error('empty response body');
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    if (value) {
      total += value.byteLength;
      if (total > MAX_UPLOAD_BYTES) {
        try { await reader.cancel(); } catch { /* ignore */ }
        throw new Error(`image exceeds ${MAX_UPLOAD_BYTES} bytes`);
      }
      chunks.push(value);
    }
  }
  const bytes = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) { bytes.set(c, off); off += c.byteLength; }

  // Header MIME is unreliable on third-party CDNs (Cloudflare R2,
  // S3 etc. often serve images as application/octet-stream). Try the
  // header first, fall back to magic-byte sniff.
  const headerMime = normalizeMime(res.headers.get('content-type') ?? '');
  const headerOk = headerMime && IMAGE_MIME_TO_EXT[headerMime];
  const sniffed = sniffImageMime(bytes);
  const mime = sniffed ?? (headerOk ? headerMime : null);
  if (!mime) {
    throw new Error(`unrecognized image type (header=${headerMime || 'none'})`);
  }
  return { bytes, mime };
}

interface ImageOutcome {
  attachmentId?: string;
  error?: string;
}

export async function sendImagesTool(
  env: Env,
  args: Record<string, unknown>,
  ctx: ToolCtx,
): Promise<string> {
  const raw = args.images;
  if (!Array.isArray(raw) || raw.length === 0) {
    return JSON.stringify({ error: 'images must be a non-empty array' });
  }
  if (raw.length > MAX_IMAGES) {
    return JSON.stringify({ error: `at most ${MAX_IMAGES} images per call` });
  }
  const entries: string[] = [];
  for (const e of raw) {
    if (typeof e !== 'string' || !e.trim()) {
      return JSON.stringify({ error: 'every images[] entry must be a non-empty string' });
    }
    entries.push(e.trim());
  }

  // Optimistic UI: open one tool chip with the count. The result chip
  // closes it once we know success / partial / total failure.
  ctx.emit('tool_call', { name: 'send_images', count: entries.length });

  const supa = serviceClient(env);
  const outcomes: ImageOutcome[] = [];
  // Serial resolution. Workers have a 128 MB memory ceiling; with
  // 25 MB/image worst case, serial keeps peak usage flat at ~25 MB
  // instead of the parallel 125 MB worst case. Each round is fast
  // enough that the user-visible latency cost is acceptable.
  for (const entry of entries) {
    try {
      const fetched = entry.startsWith('data:')
        ? decodeDataUrl(entry)
        : await fetchPublicImage(entry, ctx.signal);
      if (!IMAGE_MIME_TO_EXT[fetched.mime]) {
        outcomes.push({ error: `unsupported MIME: ${fetched.mime}` });
        continue;
      }
      const attId = await persistAttachmentBytes(
        env, supa, ctx.userId, ctx.conversationId, fetched.bytes, fetched.mime,
      );
      if (!attId) {
        outcomes.push({ error: 'persist failed' });
        continue;
      }
      outcomes.push({ attachmentId: attId });
    } catch (err) {
      outcomes.push({ error: err instanceof Error ? err.message : String(err) });
    }
  }

  const ids = outcomes.flatMap((o) => (o.attachmentId ? [o.attachmentId] : []));
  const errors = outcomes.flatMap((o) => (o.error ? [o.error] : []));

  if (ids.length === 0) {
    ctx.emit('tool_result', {
      name: 'send_images',
      count: 0,
      error: errors[0] ?? 'all images failed',
    });
    return JSON.stringify({
      ok: false,
      error: 'no images persisted',
      errors,
    });
  }

  const insertOk = await ctx.emitImagesMessage(ids);
  if (!insertOk) {
    ctx.emit('tool_result', {
      name: 'send_images',
      count: ids.length,
      error: 'message insert failed',
    });
    return JSON.stringify({
      ok: false,
      error: 'message insert failed',
      attachment_ids: ids,
    });
  }

  ctx.emit('tool_result', {
    name: 'send_images',
    count: ids.length,
    ...(errors.length > 0 ? { partial_errors: errors } : {}),
  });
  // Terminal: the round-loop in bot-reply/index.ts breaks after this
  // tool runs, so this envelope is not actually re-fed to the model.
  // We still return a coherent JSON payload for completeness / future-
  // proofing (e.g. if a wrapper ever stages send_images alongside a
  // continuation step).
  return JSON.stringify({
    ok: true,
    sent: ids.length,
    ...(errors.length > 0 ? { partial_errors: errors } : {}),
  });
}
